-- Fix: generate_invite_code used gen_random_bytes (pgcrypto), which lives in
-- the extensions schema. Security-definer functions with search_path=public
-- cannot find it. Replace with gen_random_uuid(), always available in PG 13+.
-- 256 % 32 == 0: no modulo bias, same as before.
create or replace function generate_invite_code()
returns text
language plpgsql
set search_path = public
as $$
declare
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_uuid  text := replace(gen_random_uuid()::text, '-', '');
  v_part1 text := '';
  v_part2 text := '';
  i       int;
  v_byte  int;
begin
  for i in 0..3 loop
    v_byte := ('x' || substr(v_uuid, i * 2 + 1, 2))::bit(8)::int;
    v_part1 := v_part1 || substr(v_chars, (v_byte % 32) + 1, 1);
  end loop;
  for i in 4..7 loop
    v_byte := ('x' || substr(v_uuid, i * 2 + 1, 2))::bit(8)::int;
    v_part2 := v_part2 || substr(v_chars, (v_byte % 32) + 1, 1);
  end loop;
  return v_part1 || '-' || v_part2;
end;
$$;
