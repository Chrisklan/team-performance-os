-- AP-41 (Bridge Punkt 58): Schreibrechte auf sensible public.*-Tabellen entziehen.
--
-- Befund vor dieser Migration (gemessen via information_schema.role_table_grants):
-- authenticated UND anon hatten beide vollen SELECT/INSERT/UPDATE/DELETE auf
-- public.daily_checkins, players, profiles, baselines, load_deviations, medical_records.
-- RLS wirkt zeilen-, nicht spaltenweise; seit Punkt 51 ist der Staff-Zweig auf
-- daily_checkins zu, der self-Zweig blieb aber offen fuer direkte REST-Schreibzugriffe.
--
-- Gegenmessung Schreibwege (Grep in beiden Repos):
-- - team-performance-os-player/src: keine direkten .from(...).insert/update/upsert/delete
--   auf diesen sechs Tabellen gefunden. Alle Schreibzugriffe laufen ausschliesslich ueber
--   supabase.rpc(...), u.a. rpc_submit_checkin, rpc_set_my_body_map_figure.
-- - team-performance-os (Web/Staff): ebenfalls keine direkten Schreibzugriffe im Client-Code.
--
-- Damit ist der direkte REST-Schreibweg fuer authenticated/anon auf diesen Tabellen
-- ungenutzt und kann entzogen werden, ohne einen bestehenden Schreibpfad zu brechen.
-- SELECT bleibt bestehen, RLS regelt weiterhin den Zeilenzugriff.
--
-- Freigegeben von Chris im Chat am 2026-09-25.

revoke insert, update, delete on public.daily_checkins from authenticated, anon;
revoke insert, update, delete on public.players from authenticated, anon;
revoke insert, update, delete on public.profiles from authenticated, anon;
revoke insert, update, delete on public.baselines from authenticated, anon;
revoke insert, update, delete on public.load_deviations from authenticated, anon;
revoke insert, update, delete on public.medical_records from authenticated, anon;
