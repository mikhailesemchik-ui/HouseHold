-- Remote push notification foundation.
-- Clients can register only their own device tokens. Notification rows are
-- generated server-side from trusted database actions and processed by an Edge
-- Function using service-role credentials.

create table device_push_tokens (
  id         uuid        primary key default gen_random_uuid(),
  user_id    uuid        not null references profiles(user_id) on delete cascade,
  token      text        not null,
  platform   text        not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint device_push_tokens_platform_check check (platform in ('android', 'ios')),
  constraint device_push_tokens_token_not_blank check (trim(token) <> ''),
  constraint device_push_tokens_user_token_unique unique (user_id, token)
);

create index device_push_tokens_user_id
  on device_push_tokens (user_id);

create index device_push_tokens_platform
  on device_push_tokens (platform);

create trigger device_push_tokens_updated_at
  before update on device_push_tokens
  for each row execute function set_updated_at();

alter table device_push_tokens enable row level security;

create policy "device_push_tokens_select_own"
  on device_push_tokens for select
  to authenticated
  using (auth.uid() = user_id);

create policy "device_push_tokens_insert_own"
  on device_push_tokens for insert
  to authenticated
  with check (auth.uid() = user_id);

create policy "device_push_tokens_update_own"
  on device_push_tokens for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "device_push_tokens_delete_own"
  on device_push_tokens for delete
  to authenticated
  using (auth.uid() = user_id);

create table notification_outbox (
  id                uuid        primary key default gen_random_uuid(),
  recipient_user_id uuid        not null references profiles(user_id) on delete cascade,
  household_id      uuid        null references households(id) on delete cascade,
  type              text        not null,
  title             text        not null,
  body              text        not null,
  payload           jsonb       not null default '{}'::jsonb,
  created_at        timestamptz not null default now(),
  processed_at      timestamptz null,

  constraint notification_outbox_type_not_blank check (trim(type) <> ''),
  constraint notification_outbox_title_not_blank check (trim(title) <> ''),
  constraint notification_outbox_body_not_blank check (trim(body) <> '')
);

create index notification_outbox_unprocessed
  on notification_outbox (created_at)
  where processed_at is null;

create index notification_outbox_recipient_created
  on notification_outbox (recipient_user_id, created_at desc);

alter table notification_outbox enable row level security;
-- No client policies: clients cannot read or mutate the server push outbox.

create or replace function _push_profile_name(p_user_id uuid)
returns text
language sql
security definer
stable
set search_path = public
as $$
  select nullif(trim(display_name), '')
  from profiles
  where user_id = p_user_id;
$$;

create or replace function _enqueue_notification(
  p_recipient_user_id uuid,
  p_household_id uuid,
  p_type text,
  p_title text,
  p_body text,
  p_payload jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_recipient_user_id is null
     or trim(p_type) = ''
     or trim(p_title) = ''
     or trim(p_body) = '' then
    return;
  end if;

  insert into notification_outbox (
    recipient_user_id, household_id, type, title, body, payload
  ) values (
    p_recipient_user_id, p_household_id, p_type, p_title, p_body,
    coalesce(p_payload, '{}'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Task assignment notifications.
-- Sends only when assigned_to becomes a different active household member and
-- that member is not the authenticated actor.
-- ---------------------------------------------------------------------------
create or replace function enqueue_task_assignment_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor      uuid := auth.uid();
  v_actor_name text;
  v_body       text;
begin
  if new.assigned_to is null then
    return null;
  end if;

  if tg_op = 'UPDATE' and old.assigned_to is not distinct from new.assigned_to then
    return null;
  end if;

  if new.assigned_to is not distinct from v_actor then
    return null;
  end if;

  if not exists (
    select 1
    from household_members
    where household_id = new.household_id
      and user_id      = new.assigned_to
      and status       = 'active'
  ) then
    return null;
  end if;

  v_actor_name := _push_profile_name(v_actor);
  v_body := case
    when v_actor_name is null then 'You were assigned "' || new.title || '"'
    else v_actor_name || ' assigned you "' || new.title || '"'
  end;

  perform _enqueue_notification(
    new.assigned_to,
    new.household_id,
    'task_assigned',
    'New task',
    v_body,
    jsonb_build_object(
      'type', 'task_assigned',
      'householdId', new.household_id,
      'taskId', new.id
    )
  );

  return null;
end;
$$;

create trigger tasks_enqueue_assignment_notification
  after insert or update of assigned_to on tasks
  for each row execute function enqueue_task_assignment_notification();

-- ---------------------------------------------------------------------------
-- join_household_by_invite with household-joined notifications.
-- ---------------------------------------------------------------------------
create or replace function join_household_by_invite(p_code text)
returns households
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id     uuid        := auth.uid();
  v_code        text        := upper(trim(p_code));
  v_invite      household_invites;
  v_household   households;
  v_joined_name text;
  v_recipient   uuid;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'HO000';
  end if;

  select * into v_invite
  from household_invites
  where code       = v_code
    and revoked_at is null
    and (expires_at is null or expires_at > now());

  if not found then
    raise exception 'Invite code is invalid, expired, or revoked'
      using errcode = 'HO004';
  end if;

  select * into v_household
  from households
  where id = v_invite.household_id;

  if exists (
    select 1 from household_members
    where household_id = v_household.id
      and user_id      = v_user_id
      and status       = 'active'
  ) then
    return v_household;
  end if;

  insert into household_members (household_id, user_id, role, status, joined_at, left_at)
  values (v_household.id, v_user_id, 'member', 'active', now(), null)
  on conflict (household_id, user_id) do update
    set role      = 'member',
        status    = 'active',
        joined_at = now(),
        left_at   = null;

  insert into household_membership_periods (household_id, user_id, joined_at)
  values (v_household.id, v_user_id, now())
  on conflict (household_id, user_id) where left_at is null do nothing;

  v_joined_name := coalesce(_push_profile_name(v_user_id), 'Someone');
  for v_recipient in
    select user_id
    from household_members
    where household_id = v_household.id
      and user_id     != v_user_id
      and status       = 'active'
  loop
    perform _enqueue_notification(
      v_recipient,
      v_household.id,
      'household_joined',
      v_joined_name || ' joined ' || v_household.name,
      v_joined_name || ' joined ' || v_household.name,
      jsonb_build_object(
        'type', 'household_joined',
        'householdId', v_household.id
      )
    );
  end loop;

  return v_household;
end;
$$;

-- ---------------------------------------------------------------------------
-- remove_household_member with removed-user notification.
-- ---------------------------------------------------------------------------
create or replace function remove_household_member(
  p_household_id uuid,
  p_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id   uuid        := auth.uid();
  v_left_at     timestamptz := now();
  v_target_role text;
  v_house_name  text;
begin
  if v_caller_id is null then
    raise exception 'Authentication required' using errcode = 'HO000';
  end if;

  if v_caller_id = p_user_id then
    raise exception 'Owners cannot remove themselves with this action'
      using errcode = 'HO007';
  end if;

  if not exists (
    select 1
    from household_members
    where household_id = p_household_id
      and user_id      = v_caller_id
      and role         = 'owner'
      and status       = 'active'
  ) then
    raise exception 'Only active household owners may remove members'
      using errcode = 'HO002';
  end if;

  select role into v_target_role
  from household_members
  where household_id = p_household_id
    and user_id      = p_user_id
    and status       = 'active';

  if not found then
    raise exception 'Target member is not active in this household'
      using errcode = 'HO005';
  end if;

  if v_target_role = 'owner' then
    raise exception 'Removing another owner is not supported'
      using errcode = 'HO008';
  end if;

  select name into v_house_name
  from households
  where id = p_household_id;

  update household_members
  set status  = 'left',
      left_at = v_left_at
  where household_id = p_household_id
    and user_id      = p_user_id
    and status       = 'active';

  update household_membership_periods
  set left_at = v_left_at
  where household_id = p_household_id
    and user_id      = p_user_id
    and left_at      is null;

  update tasks
  set assigned_to = null
  where household_id = p_household_id
    and assigned_to  = p_user_id
    and completed_at is null;

  update task_occurrences
  set assigned_to = null
  where household_id = p_household_id
    and assigned_to  = p_user_id
    and completed_at is null
    and scheduled_at > v_left_at;

  perform _enqueue_notification(
    p_user_id,
    p_household_id,
    'member_removed',
    'You were removed from ' || coalesce(v_house_name, 'a home'),
    'You were removed from ' || coalesce(v_house_name, 'a home'),
    jsonb_build_object(
      'type', 'member_removed',
      'householdId', p_household_id
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- transfer_household_ownership with new-owner notification.
-- ---------------------------------------------------------------------------
create or replace function transfer_household_ownership(
  p_household_id uuid,
  p_new_owner_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id uuid := auth.uid();
  v_new_role  text;
  v_house_name text;
begin
  if v_caller_id is null then
    raise exception 'Authentication required' using errcode = 'HO000';
  end if;

  if v_caller_id = p_new_owner_id then
    raise exception 'Choose another active member as the new owner'
      using errcode = 'HO009';
  end if;

  if not exists (
    select 1
    from household_members
    where household_id = p_household_id
      and user_id      = v_caller_id
      and role         = 'owner'
      and status       = 'active'
  ) then
    raise exception 'Only active household owners may transfer ownership'
      using errcode = 'HO002';
  end if;

  select role into v_new_role
  from household_members
  where household_id = p_household_id
    and user_id      = p_new_owner_id
    and status       = 'active';

  if not found then
    raise exception 'New owner must be an active member of this household'
      using errcode = 'HO005';
  end if;

  if v_new_role <> 'member' then
    raise exception 'New owner must currently be a regular member'
      using errcode = 'HO010';
  end if;

  select name into v_house_name
  from households
  where id = p_household_id;

  update household_members
  set role = case
    when user_id = v_caller_id then 'member'
    when user_id = p_new_owner_id then 'owner'
    else role
  end
  where household_id = p_household_id
    and user_id in (v_caller_id, p_new_owner_id)
    and status = 'active';

  if not exists (
    select 1
    from household_members
    where household_id = p_household_id
      and role         = 'owner'
      and status       = 'active'
  ) then
    raise exception 'Household must retain an active owner'
      using errcode = 'HO006';
  end if;

  perform _enqueue_notification(
    p_new_owner_id,
    p_household_id,
    'ownership_transferred',
    'You are now the owner of ' || coalesce(v_house_name, 'a home'),
    'You are now the owner of ' || coalesce(v_house_name, 'a home'),
    jsonb_build_object(
      'type', 'ownership_transferred',
      'householdId', p_household_id
    )
  );
end;
$$;

revoke all on function _push_profile_name(uuid) from public;
revoke all on function _enqueue_notification(uuid, uuid, text, text, text, jsonb) from public;
revoke all on function enqueue_task_assignment_notification() from public;
