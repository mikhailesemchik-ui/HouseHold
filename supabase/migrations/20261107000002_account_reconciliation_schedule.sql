-- F7B: schedule reconcile_account_deletions() every five minutes with pg_cron.
--
-- PREREQUISITE. pg_cron must be available in this database and preloaded
-- (cron.database_name must be this database). On hosted Supabase that means
-- enabling the extension first (Dashboard > Database > Extensions, or `create
-- extension pg_cron`). This migration deliberately FAILS when it is missing:
-- without the schedule, an account whose Auth user was deleted but whose
-- finalization failed would stay 'deleting' forever.
--
-- The job runs as the role that applies this migration (postgres), which owns
-- reconcile_account_deletions() and therefore needs no extra grant. No grant on
-- the cron schema or any table is added, and no key or URL is involved.
--
-- Idempotent: cron.schedule() with an existing job name updates that job, so
-- re-applying never creates a second one. pg_cron does not start a run of a job
-- while its previous run is still going. To pause:
--   select cron.alter_job((select jobid from cron.job where jobname = 'account-deletion-reconcile'), active := false);
-- To remove: select cron.unschedule('account-deletion-reconcile');
-- To monitor: cron.job_run_details (status, return_message) and, as service_role,
--   select * from account_deletion_health();

do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise exception 'pg_cron is not available: enable it before applying this migration';
  end if;
  if current_setting('cron.database_name', true) is distinct from current_database() then
    raise exception 'pg_cron is not configured for database % (cron.database_name = %)',
      current_database(), coalesce(current_setting('cron.database_name', true), 'unset');
  end if;
end $$;

create extension if not exists pg_cron;

select cron.schedule(
  'account-deletion-reconcile',
  '*/5 * * * *',
  $job$select public.reconcile_account_deletions()$job$
);

do $$
begin
  if (select count(*) from cron.job
      where jobname = 'account-deletion-reconcile'
        and active
        and schedule = '*/5 * * * *'
        and command = 'select public.reconcile_account_deletions()') <> 1 then
    raise exception 'account-deletion-reconcile is not registered exactly once';
  end if;
end $$;
