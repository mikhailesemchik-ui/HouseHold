-- refresh_my_recurring_occurrences()
-- Extends the rolling occurrence horizon for every active recurring task in
-- the caller's active households. Security-definer so it can call the private
-- _generate_occurrences_for_task helper. Idempotent: safe to call repeatedly.
create or replace function refresh_my_recurring_occurrences()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  task_row tasks%rowtype;
begin
  for task_row in
    select t.*
    from   tasks t
    inner join household_members hm
           on hm.household_id = t.household_id
    where  hm.user_id         = auth.uid()
      and  hm.status          = 'active'
      and  t.recurrence_type <> 'none'
      and  t.completed_at     is null
  loop
    perform _generate_occurrences_for_task(task_row);
  end loop;
end;
$$;

revoke all on function refresh_my_recurring_occurrences() from anon;
grant execute on function refresh_my_recurring_occurrences() to authenticated;
