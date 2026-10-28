#!/bin/zsh
# t20 - the 9:16 feed must be configured EXACTLY like the 16:9 one, title aside.
#
# The vertical template used to be a COPY of the horizontal settings with a shorter
# description and a different tag list. Copies drift: stream.sh rewrites the 16:9 reference at
# every rotation (cmd_capture), so the copy is stale within a day. It now carries only its
# overrides and inherits the rest at load time.
source "${0:A:h}/lib.sh"
t_begin t20

cd "$REPO_DIR" || exit 2
t_setup >/dev/null
mkdir -p "$T_BASE/conf"
cp conf/broadcast_template.json conf/vertical_template.json "$T_BASE/conf/"

python3 - "$T_BASE" "$REPO_DIR" <<'PY' && t_ok "the vertical template differs from the 16:9 one ONLY in the title" || t_bad "vertical and horizontal settings diverge"
import importlib.util, json, os, pathlib, sys
base, repo = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
os.environ["BASE"] = str(base)
os.environ["YT_TEMPLATE"] = str(base / "conf/vertical_template.json")
spec = importlib.util.spec_from_file_location("yt_api", repo / "bin/yt_api.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
h = json.loads((base / "conf/broadcast_template.json").read_text())
v = m.load_template()
if not v["video"]["title"].startswith(h["video"]["title"].split(" #")[0] + " #shorts"):
    print("title is not the horizontal one with #shorts", file=sys.stderr); sys.exit(1)
for sect, field in [("video", "description"), ("video", "tags"), ("video", "categoryId"),
                    ("video_status", "privacyStatus"), ("broadcast", None)]:
    if sect == "broadcast":
        if v.get("broadcast") != h.get("broadcast"): sys.exit(1)
    elif v.get(sect, {}).get(field) != h.get(sect, {}).get(field):
        sys.exit(1)
sys.exit(0)
PY

python3 - "$T_BASE" "$REPO_DIR" <<'PY' && t_ok "the parent's settings are inherited at LOAD time, not copied" || t_bad "inheritance is not applied"
import importlib.util, json, os, pathlib, sys
base, repo = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
# Add a tag to the parent only. If the child inherits, it must see it; a copy would not.
h = json.loads((base / "conf/broadcast_template.json").read_text())
h["video"]["tags"] = list(h["video"]["tags"]) + ["inheritance-probe"]
(base / "conf/broadcast_template.json").write_text(json.dumps(h))
os.environ["BASE"] = str(base)
os.environ["YT_TEMPLATE"] = str(base / "conf/vertical_template.json")
spec = importlib.util.spec_from_file_location("yt_api", repo / "bin/yt_api.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
v = m.load_template()
sys.exit(0 if "inheritance-probe" in (v.get("video", {}).get("tags") or []) else 1)
PY

python3 - "$T_BASE" "$REPO_DIR" <<'PY' && t_ok "save_template refuses to flatten an inheriting template" || t_bad "save_template can flatten the child and end the inheritance"
import importlib.util, os, pathlib, sys
base, repo = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
os.environ["BASE"] = str(base)
os.environ["YT_TEMPLATE"] = str(base / "conf/vertical_template.json")
spec = importlib.util.spec_from_file_location("yt_api", repo / "bin/yt_api.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
before = (base / "conf/vertical_template.json").read_text()
wrote = m.save_template({"video": {"title": "flattened"}})
after = (base / "conf/vertical_template.json").read_text()
sys.exit(0 if (wrote is False and before == after) else 1)
PY

python3 - "$REPO_DIR" <<'PY' && t_ok "the child still declares _inherit" || t_bad "the vertical template lost _inherit"
import json, sys
d = json.load(open(sys.argv[1] + "/conf/vertical_template.json"))
sys.exit(0 if d.get("_inherit") == "broadcast_template.json" else 1)
PY

t_teardown
t_summary
