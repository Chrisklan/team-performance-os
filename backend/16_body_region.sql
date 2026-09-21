-- =============================================================================
-- 16_body_region.sql — Regionskatalog der Body Map als Referenztabelle (AP-43)
--
-- Modul-Body-Map Abschnitt 6. Heute nimmt app.rpc_submit_checkin jeden String
-- als Region an: knie_l, knee_l und "Knie links" landen in derselben Spalte.
-- Damit zerfaellt die Historie eines Spielers beim naechsten App Update in zwei
-- Straenge. Diese Datei legt die eine Quelle in der Datenbank an, 17_ nimmt sie
-- in die Pruefung.
--
-- Referenztabelle, kein Enum (Abschnitt 6): ein Enum traegt keine Beschriftung
-- und keine Zuordnung, und ALTER TYPE ist in einer Migrationskette unangenehm.
--
-- Vier Tabellen, alle ohne team_id und ohne Personenbezug:
--   app.body_standard_area   18 IOC Areale (Bahr et al., BJSM 2020, Tabelle 4)
--   app.body_region_group    6 Bereiche fuer die gruppierte Listenansicht
--   app.body_figure_variant  6 Silhouetten aus AP-44a, fuer das Feld svg
--   app.body_region          46 Schluessel: 40 waehlbar, 6 nur lesbar
--
-- Die Quelle bleibt die Datei backend/body_regions.json. Der Datenblock unten
-- wird aus ihr erzeugt (scripts/gen-body-region-sql.mjs), nicht von Hand
-- gepflegt, und backend/16_body_region.pgtap.sql stellt Datei und Tabelle
-- gegeneinander, damit die beiden nicht auseinanderlaufen koennen.
--
-- Entscheidungen von Chris am 2026-09-21 (AP-43):
--   * Stichtag ist 2026-09-21, der Tag, an dem diese Tabelle entsteht.
--   * group wird eine Spalte (region_group), nicht nur eine Sache der App.
--   * Die svg Variante wird gegen die Liste geprueft, die Version nur auf Format.
--   * Die 6 Altschluessel ohne Flaeche bleiben in neuen Submits zulaessig,
--     solange eine App aelter als AP-44b im Umlauf ist. Dafuer traegt die
--     Tabelle active_to: ein Datum dort schaltet einen Schluessel ab, ohne die
--     Zeile und damit die Lesbarkeit alter Check-Ins zu verlieren.
--
-- Rechte: lesbar fuer authenticated (jeder im Team liest denselben Katalog,
-- es gibt nichts Team-Eigenes daran), nicht schreibbar. Schreiben nur ueber
-- eine Migration.
--
-- Voraussetzung: 08_reconciling.sql. Idempotent.
-- Tests: backend/16_body_region.pgtap.sql.
-- =============================================================================

-- =============================================================================
-- 1. Tabellen
-- =============================================================================

-- Die 18 Koerperareale der IOC Konsensempfehlung. Unsere Schluessel duerfen
-- feiner sein als der Standard, solange jeder sein Areal mittraegt: das gibt
-- den feinen Tipp-Flow und die saubere Aggregation zugleich (Abschnitt 6).
CREATE TABLE IF NOT EXISTS app.body_standard_area (
  key         text PRIMARY KEY,
  ioc_area    text NOT NULL,
  ioc_region  text NOT NULL,
  osiics      text NOT NULL,
  smdcs       text NOT NULL
);

-- Die sechs Bereiche der Listenansicht. Sie ist der Weg fuer VoiceOver und
-- eingeschraenkte Feinmotorik, und 40 Zeilen am Stueck sind dort unzumutbar.
CREATE TABLE IF NOT EXISTS app.body_region_group (
  id        text PRIMARY KEY,
  label_de  text NOT NULL,
  sort      integer NOT NULL UNIQUE
);

-- Die sechs Silhouetten. Der Tippunkt ist ohne seine Figur nicht lesbar: ein
-- Punkt auf weiblich_vorne zeigt auf maennlich_hinten irgendwohin.
CREATE TABLE IF NOT EXISTS app.body_figure_variant (
  key      text PRIMARY KEY,
  figur    text NOT NULL,
  ansicht  text NOT NULL,
  sort     integer NOT NULL UNIQUE,
  CONSTRAINT body_figure_variant_figur_ck   CHECK (figur   IN ('weiblich', 'maennlich', 'neutral')),
  CONSTRAINT body_figure_variant_ansicht_ck CHECK (ansicht IN ('vorne', 'hinten')),
  CONSTRAINT body_figure_variant_key_ck     CHECK (key = figur || '_' || ansicht)
);

CREATE TABLE IF NOT EXISTS app.body_region (
  key                 text PRIMARY KEY,
  label_de            text NOT NULL,
  -- side steuert, auf welcher Figur die Flaeche liegt, und ist zugleich der
  -- Schalter fuer waehlbar: NULL heisst kein Pfad auf der Silhouette.
  side                text,
  lateral_side        text,
  region_group        text REFERENCES app.body_region_group(id),
  standard_area       text REFERENCES app.body_standard_area(key),
  sort                integer NOT NULL UNIQUE,
  active_from         date NOT NULL,
  -- active_to ist der Abschalter fuer Altschluessel (Entscheidung 1). NULL
  -- heisst gilt weiter. Eine abgeschaltete Zeile bleibt stehen, sonst waeren
  -- alte Check-Ins nicht mehr beschriftbar.
  active_to           date,
  standard_area_note  text,
  standard_area_open  text,
  is_selectable       boolean GENERATED ALWAYS AS (side IS NOT NULL) STORED,
  CONSTRAINT body_region_side_ck    CHECK (side    IS NULL OR side    IN ('front', 'back', 'both')),
  CONSTRAINT body_region_lateral_ck CHECK (lateral_side IS NULL OR lateral_side IN ('l', 'r')),
  CONSTRAINT body_region_range_ck   CHECK (active_to IS NULL OR active_to > active_from),
  -- Waehlbar heisst: Flaeche, Bereich in der Liste und ein Standard Areal.
  -- Die drei offenen Zuordnungen betreffen nur Altschluessel ohne Flaeche.
  CONSTRAINT body_region_group_ck   CHECK ((region_group  IS NULL) = (side IS NULL)),
  CONSTRAINT body_region_area_ck    CHECK (standard_area IS NOT NULL OR side IS NULL),
  -- Entweder zugeordnet oder mit Begruendung offen, nie einfach leer.
  CONSTRAINT body_region_open_ck    CHECK (standard_area IS NOT NULL OR standard_area_open IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS body_region_sort_idx  ON app.body_region (sort);
CREATE INDEX IF NOT EXISTS body_region_group_idx ON app.body_region (region_group, sort);

COMMENT ON TABLE app.body_region IS
  'AP-43: Regionskatalog der Body Map, eine Quelle fuer Liste, Silhouette und '
  'die Pruefung in app.rpc_submit_checkin. Erzeugt aus backend/body_regions.json, '
  'Aenderungen gehoeren in die Datei und dann in eine Migration.';
COMMENT ON COLUMN app.body_region.side IS 'front, back oder both. NULL heisst: keine Flaeche auf der Silhouette, nicht waehlbar (Altschluessel ohne Nachfolger).';
COMMENT ON COLUMN app.body_region.lateral_side IS 'l oder r meinen die Seite des Spielers, nicht die Bildseite. Heisst nicht lateral, weil das in SQL ein reserviertes Wort ist (LATERAL Join).';
COMMENT ON COLUMN app.body_region.region_group IS 'Bereich der gruppierten Listenansicht. Heisst nicht group, weil das in SQL ein reserviertes Wort ist.';
COMMENT ON COLUMN app.body_region.standard_area IS 'Rollup auf das IOC Areal (Bahr et al., BJSM 2020, Tabelle 4). Macht die Daten ausserhalb von TPOS lesbar.';
COMMENT ON COLUMN app.body_region.active_to IS 'Abschalter. Gesetzt heisst: in neuen Check-Ins nicht mehr zulaessig, in alten weiter beschriftet.';

-- =============================================================================
-- 2. Der Katalog als Funktion
--
-- Der Datenblock steht hier einmal und wird von den INSERTs unten zweimal
-- gelesen (einfuegen und aufraeumen). Eine Funktion statt zweier Kopien, damit
-- die Datei nicht an zwei Stellen gepflegt werden muss.
-- Erzeugt von scripts/gen-body-region-sql.mjs, nicht von Hand aendern.
-- =============================================================================

-- >>> GENERIERT AUS backend/body_regions.json — NICHT VON HAND AENDERN
-- Erzeugt von scripts/gen-body-region-sql.mjs. Aenderungen gehoeren in
-- backend/body_regions.json, danach das Skript erneut laufen lassen.
-- Stand der Quelle: 46 Eintraege, Stichtag 2026-09-21.
CREATE OR REPLACE FUNCTION app.body_region_catalog()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT $bodyregions${"_kommentar":"Regionskatalog Body Map (TPOS Modul 1b, AP-43a). Eine Quelle für Liste, Silhouette und später die Prüfung in rpc_submit_checkin. 23 Regionen, 17 seitengetrennt, 40 wählbare Schlüssel, dazu 6 lesbare Altschlüssel. Geprüft mit scripts/check-body-regions.mjs.","_quelle":{"titel":"International Olympic Committee consensus statement: methods for recording and reporting of epidemiological data on injury and illness in sport 2020 (including STROBE Extension for Sport Injury and Illness Surveillance (STROBE-SIIS))","autoren":"Bahr R, Clarsen B, Derman W, et al.","zeitschrift":"Br J Sports Med 2020;54(7):372-389","doi":"10.1136/bjsports-2019-101969","stelle":"Tabelle 4: Recommended categories of body regions and areas for injuries (18 Areale, Codes OSIICS und SMDCS)","abgerufen":"2026-09-20","abgerufen_ueber":"Europe PMC Volltext (PMC7146946), Tabelle im Rohtext gelesen, nicht aus dem Gedächtnis"},"_meta":{"stichtag":"2026-09-21","stichtag_vorlaeufig":false,"stichtag_hinweis":"Festgelegt am 2026-09-21 durch Chris (AP-43). Der Tag, an dem app.body_region entstand und die Regionspruefung in rpc_submit_checkin scharf wurde. active_from ist dokumentarisch, die Pruefung schaut auf Existenz und Waehlbarkeit, nicht auf das Datum.","legacy_active_from":"2000-01-01","legacy_hinweis":"Sammelwert für \"seit Beginn\". Gilt für alle 19 Altschlüssel, auch für die 13, die im neuen Zuschnitt unverändert weiterleben.","aktiv":"Ein Eintrag ist wählbar und hat eine Fläche auf der Silhouette, wenn side nicht null ist. Die 6 Altschlüssel ohne Nachfolger haben side null, sind nicht wählbar und bleiben für die Physio Sicht lesbar.","lateral":"l und r meinen die Seite des Spielers. In der Ansicht vorne liegt l im Bild rechts, in der Ansicht hinten liegt l im Bild links.","figure_variants":[{"key":"weiblich_vorne","figur":"weiblich","ansicht":"vorne","sort":10},{"key":"weiblich_hinten","figur":"weiblich","ansicht":"hinten","sort":20},{"key":"maennlich_vorne","figur":"maennlich","ansicht":"vorne","sort":30},{"key":"maennlich_hinten","figur":"maennlich","ansicht":"hinten","sort":40},{"key":"neutral_vorne","figur":"neutral","ansicht":"vorne","sort":50},{"key":"neutral_hinten","figur":"neutral","ansicht":"hinten","sort":60}],"figure_variants_hinweis":"Die sechs Silhouetten aus AP-44a (team-performance-os-player, assets/bodymap). Der gespeicherte Tippunkt traegt sie im Feld svg als <variante>@<version>, zum Beispiel weiblich_vorne@1. Entscheidung Chris 2026-09-21: die Variante wird serverseitig gegen diese Liste geprueft, die Version nur auf Format. Eine neue Figur ist damit eine Datenzeile, keine Schemaaenderung.","groups":[{"id":"kopf_nacken","label_de":"Kopf und Nacken","sort":10},{"id":"arm_hand","label_de":"Arm und Hand","sort":20},{"id":"rumpf","label_de":"Rumpf","sort":30},{"id":"huefte_oberschenkel","label_de":"Hüfte und Oberschenkel","sort":40},{"id":"knie_unterschenkel","label_de":"Knie und Unterschenkel","sort":50},{"id":"fuss","label_de":"Fuß","sort":60}],"standard_areas":{"head":{"ioc_area":"Head","ioc_region":"Head and neck","osiics":"H","smdcs":"HE"},"neck":{"ioc_area":"Neck","ioc_region":"Head and neck","osiics":"N","smdcs":"NE"},"shoulder":{"ioc_area":"Shoulder","ioc_region":"Upper limb","osiics":"S","smdcs":"SH"},"upper_arm":{"ioc_area":"Upper arm","ioc_region":"Upper limb","osiics":"U","smdcs":"AR"},"elbow":{"ioc_area":"Elbow","ioc_region":"Upper limb","osiics":"E","smdcs":"EL"},"forearm":{"ioc_area":"Forearm","ioc_region":"Upper limb","osiics":"R","smdcs":"FA"},"wrist":{"ioc_area":"Wrist","ioc_region":"Upper limb","osiics":"W","smdcs":"WR"},"hand":{"ioc_area":"Hand","ioc_region":"Upper limb","osiics":"P","smdcs":"HA"},"chest":{"ioc_area":"Chest","ioc_region":"Trunk","osiics":"C","smdcs":"CH"},"thoracic_spine":{"ioc_area":"Thoracic spine","ioc_region":"Trunk","osiics":"D","smdcs":"TS"},"lumbosacral":{"ioc_area":"Lumbosacral","ioc_region":"Trunk","osiics":"L","smdcs":"LS"},"abdomen":{"ioc_area":"Abdomen","ioc_region":"Trunk","osiics":"O","smdcs":"AB"},"hip_groin":{"ioc_area":"Hip/groin","ioc_region":"Lower limb","osiics":"G","smdcs":"HI"},"thigh":{"ioc_area":"Thigh","ioc_region":"Lower limb","osiics":"T","smdcs":"TH"},"knee":{"ioc_area":"Knee","ioc_region":"Lower limb","osiics":"K","smdcs":"KN"},"lower_leg":{"ioc_area":"Lower leg","ioc_region":"Lower limb","osiics":"Q","smdcs":"LE"},"ankle":{"ioc_area":"Ankle","ioc_region":"Lower limb","osiics":"A","smdcs":"AN"},"foot":{"ioc_area":"Foot","ioc_region":"Lower limb","osiics":"F","smdcs":"FO"}}},"regions":[{"key":"kopf","label_de":"Kopf","side":"both","lateral":null,"group":"kopf_nacken","standard_area":"head","sort":10,"active_from":"2026-09-21","standard_area_note":"Tabelle 4: \"Includes facial, brain (concussion), eyes, ears, teeth.\""},{"key":"nacken","label_de":"Nacken","side":"both","lateral":null,"group":"kopf_nacken","standard_area":"neck","sort":20,"active_from":"2000-01-01","standard_area_note":"Tabelle 4: \"Includes cervical spine, larynx, major vessels.\""},{"key":"schulter_l","label_de":"Schulter links","side":"both","lateral":"l","group":"arm_hand","standard_area":"shoulder","sort":30,"active_from":"2000-01-01"},{"key":"schulter_r","label_de":"Schulter rechts","side":"both","lateral":"r","group":"arm_hand","standard_area":"shoulder","sort":40,"active_from":"2000-01-01"},{"key":"oberarm_l","label_de":"Oberarm links","side":"both","lateral":"l","group":"arm_hand","standard_area":"upper_arm","sort":50,"active_from":"2000-01-01"},{"key":"oberarm_r","label_de":"Oberarm rechts","side":"both","lateral":"r","group":"arm_hand","standard_area":"upper_arm","sort":60,"active_from":"2000-01-01"},{"key":"ellbogen_l","label_de":"Ellbogen links","side":"both","lateral":"l","group":"arm_hand","standard_area":"elbow","sort":70,"active_from":"2026-09-21"},{"key":"ellbogen_r","label_de":"Ellbogen rechts","side":"both","lateral":"r","group":"arm_hand","standard_area":"elbow","sort":80,"active_from":"2026-09-21"},{"key":"unterarm_l","label_de":"Unterarm links","side":"both","lateral":"l","group":"arm_hand","standard_area":"forearm","sort":90,"active_from":"2026-09-21"},{"key":"unterarm_r","label_de":"Unterarm rechts","side":"both","lateral":"r","group":"arm_hand","standard_area":"forearm","sort":100,"active_from":"2026-09-21"},{"key":"handgelenk_l","label_de":"Handgelenk links","side":"both","lateral":"l","group":"arm_hand","standard_area":"wrist","sort":110,"active_from":"2026-09-21","standard_area_note":"Tabelle 4: \"Carpus.\""},{"key":"handgelenk_r","label_de":"Handgelenk rechts","side":"both","lateral":"r","group":"arm_hand","standard_area":"wrist","sort":120,"active_from":"2026-09-21","standard_area_note":"Tabelle 4: \"Carpus.\""},{"key":"hand_finger_l","label_de":"Hand und Finger links","side":"both","lateral":"l","group":"arm_hand","standard_area":"hand","sort":130,"active_from":"2026-09-21","standard_area_note":"Tabelle 4: \"Includes finger, thumb.\""},{"key":"hand_finger_r","label_de":"Hand und Finger rechts","side":"both","lateral":"r","group":"arm_hand","standard_area":"hand","sort":140,"active_from":"2026-09-21","standard_area_note":"Tabelle 4: \"Includes finger, thumb.\""},{"key":"brust","label_de":"Brust","side":"front","lateral":null,"group":"rumpf","standard_area":"chest","sort":150,"active_from":"2000-01-01"},{"key":"bauch","label_de":"Bauch","side":"front","lateral":null,"group":"rumpf","standard_area":"abdomen","sort":160,"active_from":"2026-09-21"},{"key":"oberruecken","label_de":"Oberrücken","side":"back","lateral":null,"group":"rumpf","standard_area":"thoracic_spine","sort":170,"active_from":"2026-09-21"},{"key":"lws_kreuz","label_de":"LWS und Kreuz","side":"back","lateral":null,"group":"rumpf","standard_area":"lumbosacral","sort":180,"active_from":"2000-01-01","standard_area_note":"Tabelle 4: \"Includes lumbar spine, sacroiliac joints, sacrum, coccyx, buttocks.\""},{"key":"huefte_l","label_de":"Hüfte links","side":"both","lateral":"l","group":"huefte_oberschenkel","standard_area":"hip_groin","sort":190,"active_from":"2026-09-21"},{"key":"huefte_r","label_de":"Hüfte rechts","side":"both","lateral":"r","group":"huefte_oberschenkel","standard_area":"hip_groin","sort":200,"active_from":"2026-09-21"},{"key":"leiste_l","label_de":"Leiste links","side":"front","lateral":"l","group":"huefte_oberschenkel","standard_area":"hip_groin","sort":210,"active_from":"2026-09-21","standard_area_note":"Tabelle 4: Hip/groin umfasst \"pubic symphysis, proximal adductors, iliopsoas\"."},{"key":"leiste_r","label_de":"Leiste rechts","side":"front","lateral":"r","group":"huefte_oberschenkel","standard_area":"hip_groin","sort":220,"active_from":"2026-09-21","standard_area_note":"Tabelle 4: Hip/groin umfasst \"pubic symphysis, proximal adductors, iliopsoas\"."},{"key":"gesaess_l","label_de":"Gesäß links","side":"back","lateral":"l","group":"huefte_oberschenkel","standard_area":"lumbosacral","sort":230,"active_from":"2026-09-21","standard_area_note":"Tabelle 4 führt \"buttocks\" unter Lumbosacral, nicht unter Hip/groin oder Thigh. Zuordnung folgt der Quelle."},{"key":"gesaess_r","label_de":"Gesäß rechts","side":"back","lateral":"r","group":"huefte_oberschenkel","standard_area":"lumbosacral","sort":240,"active_from":"2026-09-21","standard_area_note":"Tabelle 4 führt \"buttocks\" unter Lumbosacral, nicht unter Hip/groin oder Thigh. Zuordnung folgt der Quelle."},{"key":"oberschenkel_vorne_l","label_de":"Oberschenkel vorne links","side":"front","lateral":"l","group":"huefte_oberschenkel","standard_area":"thigh","sort":250,"active_from":"2026-09-21","standard_area_note":"Tabelle 4: Thigh umfasst \"quadriceps, mid-distal adductors\"."},{"key":"oberschenkel_vorne_r","label_de":"Oberschenkel vorne rechts","side":"front","lateral":"r","group":"huefte_oberschenkel","standard_area":"thigh","sort":260,"active_from":"2026-09-21","standard_area_note":"Tabelle 4: Thigh umfasst \"quadriceps, mid-distal adductors\"."},{"key":"oberschenkel_hinten_l","label_de":"Oberschenkel hinten links","side":"back","lateral":"l","group":"huefte_oberschenkel","standard_area":"thigh","sort":270,"active_from":"2026-09-21","standard_area_note":"Tabelle 4: Thigh umfasst \"hamstrings (including ischial tuberosity)\"."},{"key":"oberschenkel_hinten_r","label_de":"Oberschenkel hinten rechts","side":"back","lateral":"r","group":"huefte_oberschenkel","standard_area":"thigh","sort":280,"active_from":"2026-09-21","standard_area_note":"Tabelle 4: Thigh umfasst \"hamstrings (including ischial tuberosity)\"."},{"key":"knie_l","label_de":"Knie links","side":"both","lateral":"l","group":"knie_unterschenkel","standard_area":"knee","sort":290,"active_from":"2000-01-01","standard_area_note":"Tabelle 4: \"Includes patella, patellar tendon, pes anserinus.\" Kniekehle ist bewusst kein eigener Schlüssel."},{"key":"knie_r","label_de":"Knie rechts","side":"both","lateral":"r","group":"knie_unterschenkel","standard_area":"knee","sort":300,"active_from":"2000-01-01","standard_area_note":"Tabelle 4: \"Includes patella, patellar tendon, pes anserinus.\" Kniekehle ist bewusst kein eigener Schlüssel."},{"key":"schienbein_l","label_de":"Schienbein links","side":"front","lateral":"l","group":"knie_unterschenkel","standard_area":"lower_leg","sort":310,"active_from":"2026-09-21","standard_area_note":"Tabelle 4: Lower leg umfasst \"non-articular tibia and fibular injuries\"."},{"key":"schienbein_r","label_de":"Schienbein rechts","side":"front","lateral":"r","group":"knie_unterschenkel","standard_area":"lower_leg","sort":320,"active_from":"2026-09-21","standard_area_note":"Tabelle 4: Lower leg umfasst \"non-articular tibia and fibular injuries\"."},{"key":"wade_l","label_de":"Wade links","side":"back","lateral":"l","group":"knie_unterschenkel","standard_area":"lower_leg","sort":330,"active_from":"2000-01-01","standard_area_note":"Tabelle 4: Lower leg umfasst \"calf\"."},{"key":"wade_r","label_de":"Wade rechts","side":"back","lateral":"r","group":"knie_unterschenkel","standard_area":"lower_leg","sort":340,"active_from":"2000-01-01","standard_area_note":"Tabelle 4: Lower leg umfasst \"calf\"."},{"key":"sprunggelenk_l","label_de":"Sprunggelenk links","side":"both","lateral":"l","group":"fuss","standard_area":"ankle","sort":350,"active_from":"2026-09-21","standard_area_note":"Tabelle 4: \"Includes syndesmosis, talocrural and subtalar joints.\""},{"key":"sprunggelenk_r","label_de":"Sprunggelenk rechts","side":"both","lateral":"r","group":"fuss","standard_area":"ankle","sort":360,"active_from":"2026-09-21","standard_area_note":"Tabelle 4: \"Includes syndesmosis, talocrural and subtalar joints.\""},{"key":"achillessehne_l","label_de":"Achillessehne links","side":"back","lateral":"l","group":"fuss","standard_area":"lower_leg","sort":370,"active_from":"2026-09-21","standard_area_note":"Tabelle 4 führt \"Achilles tendon\" unter Lower leg, nicht unter Ankle oder Foot. Zuordnung folgt der Quelle."},{"key":"achillessehne_r","label_de":"Achillessehne rechts","side":"back","lateral":"r","group":"fuss","standard_area":"lower_leg","sort":380,"active_from":"2026-09-21","standard_area_note":"Tabelle 4 führt \"Achilles tendon\" unter Lower leg, nicht unter Ankle oder Foot. Zuordnung folgt der Quelle."},{"key":"fuss_l","label_de":"Fuß links","side":"both","lateral":"l","group":"fuss","standard_area":"foot","sort":390,"active_from":"2000-01-01","standard_area_note":"Tabelle 4: \"Includes toes, calcaneus, plantar fascia.\""},{"key":"fuss_r","label_de":"Fuß rechts","side":"both","lateral":"r","group":"fuss","standard_area":"foot","sort":400,"active_from":"2000-01-01","standard_area_note":"Tabelle 4: \"Includes toes, calcaneus, plantar fascia.\""},{"key":"ellbogen_unterarm_l","label_de":"Ellbogen/Unterarm links","side":null,"lateral":"l","group":null,"standard_area":null,"sort":910,"active_from":"2000-01-01","standard_area_open":"Deckt zwei IOC Areale ab (Elbow und Forearm). Ein einzelnes Areal ist nicht ohne Raten zuweisbar."},{"key":"ellbogen_unterarm_r","label_de":"Ellbogen/Unterarm rechts","side":null,"lateral":"r","group":null,"standard_area":null,"sort":920,"active_from":"2000-01-01","standard_area_open":"Deckt zwei IOC Areale ab (Elbow und Forearm). Ein einzelnes Areal ist nicht ohne Raten zuweisbar."},{"key":"hand_l","label_de":"Hand links","side":null,"lateral":"l","group":null,"standard_area":"hand","sort":930,"active_from":"2000-01-01","standard_area_note":"Altdaten: Handgelenk hatte keinen eigenen Schlüssel, Beschwerden am Handgelenk können unter diesem Schlüssel liegen."},{"key":"hand_r","label_de":"Hand rechts","side":null,"lateral":"r","group":null,"standard_area":"hand","sort":940,"active_from":"2000-01-01","standard_area_note":"Altdaten: Handgelenk hatte keinen eigenen Schlüssel, Beschwerden am Handgelenk können unter diesem Schlüssel liegen."},{"key":"ruecken_oberruecken","label_de":"Rücken/Oberrücken","side":null,"lateral":null,"group":null,"standard_area":null,"sort":950,"active_from":"2000-01-01","standard_area_open":"Das Label nennt Rücken allgemein und Oberrücken. Thoracic spine oder Lumbosacral ist nicht entscheidbar ohne Raten."},{"key":"huefte","label_de":"Hüfte","side":null,"lateral":null,"group":null,"standard_area":"hip_groin","sort":960,"active_from":"2000-01-01"}]}$bodyregions$::jsonb;
$fn$;
-- <<< ENDE GENERIERT

REVOKE EXECUTE ON FUNCTION app.body_region_catalog() FROM PUBLIC;

COMMENT ON FUNCTION app.body_region_catalog() IS
  'AP-43: woertliche Kopie von backend/body_regions.json, erzeugt von '
  'scripts/gen-body-region-sql.mjs. Nur Befuellung dieser Migration, kein Leseweg '
  'fuer Clients. backend/16_body_region.pgtap.sql stellt Datei und Tabelle gegeneinander.';

-- =============================================================================
-- 3. Befuellung
-- =============================================================================

INSERT INTO app.body_standard_area (key, ioc_area, ioc_region, osiics, smdcs)
SELECT a.key, a.value ->> 'ioc_area', a.value ->> 'ioc_region', a.value ->> 'osiics', a.value ->> 'smdcs'
  FROM jsonb_each(app.body_region_catalog() #> '{_meta,standard_areas}') a
    ON CONFLICT (key) DO UPDATE SET
       ioc_area   = EXCLUDED.ioc_area,
       ioc_region = EXCLUDED.ioc_region,
       osiics     = EXCLUDED.osiics,
       smdcs      = EXCLUDED.smdcs;

INSERT INTO app.body_region_group (id, label_de, sort)
SELECT g.id, g.label_de, g.sort
  FROM jsonb_to_recordset(app.body_region_catalog() #> '{_meta,groups}')
       AS g(id text, label_de text, sort integer)
    ON CONFLICT (id) DO UPDATE SET
       label_de = EXCLUDED.label_de,
       sort     = EXCLUDED.sort;

INSERT INTO app.body_figure_variant (key, figur, ansicht, sort)
SELECT v.key, v.figur, v.ansicht, v.sort
  FROM jsonb_to_recordset(app.body_region_catalog() #> '{_meta,figure_variants}')
       AS v(key text, figur text, ansicht text, sort integer)
    ON CONFLICT (key) DO UPDATE SET
       figur   = EXCLUDED.figur,
       ansicht = EXCLUDED.ansicht,
       sort    = EXCLUDED.sort;

INSERT INTO app.body_region (
  key, label_de, side, lateral_side, region_group, standard_area, sort, active_from,
  standard_area_note, standard_area_open
)
SELECT r.key, r.label_de, r.side, r."lateral", r."group", r.standard_area, r.sort,
       r.active_from, r.standard_area_note, r.standard_area_open
  FROM jsonb_to_recordset(app.body_region_catalog() -> 'regions')
       AS r(key text, label_de text, side text, "lateral" text, "group" text,
            standard_area text, sort integer, active_from date,
            standard_area_note text, standard_area_open text)
    ON CONFLICT (key) DO UPDATE SET
       label_de           = EXCLUDED.label_de,
       side               = EXCLUDED.side,
       lateral_side       = EXCLUDED.lateral_side,
       region_group       = EXCLUDED.region_group,
       standard_area      = EXCLUDED.standard_area,
       sort               = EXCLUDED.sort,
       active_from        = EXCLUDED.active_from,
       standard_area_note = EXCLUDED.standard_area_note,
       standard_area_open = EXCLUDED.standard_area_open;

-- Schluessel, die aus der Datei verschwunden sind, verschwinden auch aus der
-- Tabelle. Das ist der zweite Teil von "die Datei ist die Quelle". Ein
-- Schluessel, auf den Check-Ins zeigen, wird nicht geloescht, sondern in der
-- Datei mit active_to abgeschaltet.
DELETE FROM app.body_region r
 WHERE NOT EXISTS (
   SELECT 1 FROM jsonb_array_elements(app.body_region_catalog() -> 'regions') e
    WHERE e ->> 'key' = r.key);

-- =============================================================================
-- 4. RLS und Rechte
--
-- Referenzdaten ohne Personen- und Teambezug: jeder Angemeldete liest denselben
-- Katalog. Geschrieben wird nur per Migration, deshalb gibt es fuer
-- authenticated keine INSERT, UPDATE oder DELETE Policy und kein Grant darauf.
-- =============================================================================

ALTER TABLE app.body_standard_area  ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.body_region_group   ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.body_figure_variant ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.body_region         ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS body_standard_area_select  ON app.body_standard_area;
DROP POLICY IF EXISTS body_region_group_select   ON app.body_region_group;
DROP POLICY IF EXISTS body_figure_variant_select ON app.body_figure_variant;
DROP POLICY IF EXISTS body_region_select         ON app.body_region;

CREATE POLICY body_standard_area_select  ON app.body_standard_area  FOR SELECT TO authenticated USING (true);
CREATE POLICY body_region_group_select   ON app.body_region_group   FOR SELECT TO authenticated USING (true);
CREATE POLICY body_figure_variant_select ON app.body_figure_variant FOR SELECT TO authenticated USING (true);
CREATE POLICY body_region_select         ON app.body_region         FOR SELECT TO authenticated USING (true);

GRANT SELECT ON app.body_standard_area  TO authenticated;
GRANT SELECT ON app.body_region_group   TO authenticated;
GRANT SELECT ON app.body_figure_variant TO authenticated;
GRANT SELECT ON app.body_region         TO authenticated;

-- anon hat im Schema app seit Migration 20260921000024 nichts mehr (AP-39b).
-- Die vier Tabellen sind neu, deshalb der Entzug hier noch einmal ausdruecklich.
REVOKE ALL ON app.body_standard_area  FROM anon;
REVOKE ALL ON app.body_region_group   FROM anon;
REVOKE ALL ON app.body_figure_variant FROM anon;
REVOKE ALL ON app.body_region         FROM anon;

GRANT ALL ON app.body_standard_area  TO service_role;
GRANT ALL ON app.body_region_group   TO service_role;
GRANT ALL ON app.body_figure_variant TO service_role;
GRANT ALL ON app.body_region         TO service_role;
