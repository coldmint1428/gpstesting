-- ============================================================
-- The data no_marshals_test.sql checks, written BEFORE 077_no_marshals.sql (as an event held before 077 would be).
-- Locally: `node tools/pgtest.mjs roles-077` applies it between 076's predecessors and 077.
-- ============================================================

-- R root, P planner; group G: A (admin), M (a marshal and IC), U; group H: V (IC); N a marshal row only, no group
insert into auth.users (id, email, raw_user_meta_data) values
  ('77000000-0000-0000-0000-000000000001', 'nm-r@example.test', '{"username":"nm_r","display_name":"Nm Root"}'),
  ('77000000-0000-0000-0000-000000000002', 'nm-p@example.test', '{"username":"nm_p","display_name":"Nm Planner"}'),
  ('77000000-0000-0000-0000-000000000003', 'nm-a@example.test', '{"username":"nm_a","display_name":"Nm Admin"}'),
  ('77000000-0000-0000-0000-000000000004', 'nm-m@example.test', '{"username":"nm_m","display_name":"Nm Em"}'),
  ('77000000-0000-0000-0000-000000000005', 'nm-u@example.test', '{"username":"nm_u","display_name":"Nm User"}'),
  ('77000000-0000-0000-0000-000000000006', 'nm-v@example.test', '{"username":"nm_v","display_name":"Nm Vee"}'),
  ('77000000-0000-0000-0000-000000000007', 'nm-n@example.test', '{"username":"nm_n","display_name":"Nm None"}');
insert into public.events (id, name, created_by) values ('77000000-0000-0000-0000-0000000000e1', 'No marshals test', '77000000-0000-0000-0000-000000000001');
insert into public.event_roles (event_id, user_id, role) values
  ('77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000001', 'root'),
  ('77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000002', 'participant'),
  ('77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000002', 'planner'),
  ('77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000003', 'participant'),
  ('77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000004', 'participant'),
  ('77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000004', 'marshal'),
  ('77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000005', 'participant'),
  ('77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000006', 'participant'),
  ('77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000007', 'marshal')
  on conflict do nothing;
insert into public.groups (id, event_id, name) values
  ('77000000-0000-0000-0000-0000000000a1', '77000000-0000-0000-0000-0000000000e1', 'G'),
  ('77000000-0000-0000-0000-0000000000a2', '77000000-0000-0000-0000-0000000000e1', 'H');
insert into public.group_members (group_id, event_id, user_id, is_admin, is_ic) values
  ('77000000-0000-0000-0000-0000000000a1', '77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000003', true, false),
  ('77000000-0000-0000-0000-0000000000a1', '77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000004', false, true),
  ('77000000-0000-0000-0000-0000000000a1', '77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000005', false, false),
  ('77000000-0000-0000-0000-0000000000a2', '77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-000000000006', false, true);
-- One location in each group; G's came from a manual mark (003 allowed the source, nothing ever wrote one)
insert into public.locations (event_id, group_id, user_id, lat, lng, accuracy, source, recorded_at) values
  ('77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-0000000000a1', '77000000-0000-0000-0000-000000000004', 1.29, 103.85, 5, 'marshal', now()),
  ('77000000-0000-0000-0000-0000000000e1', '77000000-0000-0000-0000-0000000000a2', '77000000-0000-0000-0000-000000000006', 1.30, 103.86, 5, 'gps', now());
