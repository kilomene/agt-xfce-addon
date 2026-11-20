#!/bin/sh
# session-run.sh <agent>: the deployment start command for one
# agent's XFCE session. Execs the python session runner that lives
# beside this script in the add-on.
exec /data/data/com.novainc.agt/files/usr/bin/python3 \
  /data/data/com.novainc.agt/files/addons/xfce/share/xview/session_run.py "$1"
