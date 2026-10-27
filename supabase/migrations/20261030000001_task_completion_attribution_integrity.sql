-- Task completion attribution integrity (follow-up to audit finding F11).
--
-- tasks: enforce_task_completion_identity only checked the moment a task
-- became completed, so any member could rewrite completed_by / completed_at
-- on an already-completed task with a direct update. Once completed, those
-- columns are now frozen until the task is reopened (both set to null);
-- completion must still name the authenticated user.
--
-- task_occurrences: clients have no write grant; completion goes through
-- complete_occurrence / reopen_occurrence, which already record auth.uid() and
-- never rewrite a completed row. A guard trigger adds the same freeze for any
-- other writer, as defense in depth. Completing and reopening through the
-- RPCs, assignment changes, refresh and schedule edits do not touch completion
-- columns and are unaffected. Existing rows are not modified.

create or replace function enforce_task_completion_identity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.completed_at is null and new.completed_at is not null then
    if new.completed_by is distinct from auth.uid() then
      raise exception 'completed_by must be the authenticated user when completing a task'
        using errcode = 'TK001';
    end if;
  elsif old.completed_at is not null and new.completed_at is not null then
    if new.completed_by is distinct from old.completed_by
       or new.completed_at is distinct from old.completed_at then
      raise exception 'completion of a task cannot be rewritten; reopen it first'
        using errcode = 'TK002';
    end if;
  end if;
  return new;
end;
$$;

create or replace function enforce_occurrence_completion_freeze()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.completed_at is not null and new.completed_at is not null then
    if new.completed_by is distinct from old.completed_by
       or new.completed_at is distinct from old.completed_at then
      raise exception 'completion of an occurrence cannot be rewritten; reopen it first'
        using errcode = 'TK004';
    end if;
  end if;
  return new;
end;
$$;

create trigger task_occurrences_completion_freeze
  before update on task_occurrences
  for each row execute function enforce_occurrence_completion_freeze();
