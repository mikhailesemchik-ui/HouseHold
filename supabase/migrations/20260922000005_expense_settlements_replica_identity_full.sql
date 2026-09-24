-- SET-001: expense_settlements realtime DELETE events were silently dropped
-- for the app's filtered subscription (`.eq('household_id', ...)`), and the
-- DELETE RLS policy (settlements_delete_creator) also depends on
-- household_id. Default replica identity omits that non-primary-key column
-- from the old row, so Realtime cannot match/deliver the DELETE. Same
-- mechanism physically proven and fixed for shopping_items (20260922000001),
-- tasks (000002), expenses (000003) and task_occurrences (000004).
alter table expense_settlements replica identity full;
