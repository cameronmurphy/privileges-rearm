#!/bin/bash
# privileges-rearm.sh
#
# When SAP Privileges admin expires, auto-open the request dialog, pick the
# "Developer Requirement" reason FROM THE DROPDOWN (no typing), and click
# Request Privileges — leaving ONLY the Touch ID tap for you. Your fingerprint
# is still required, so this can never complete an elevation on its own.
#
# Because it never types, it can't collide with your keyboard. It does move the
# mouse for ~1s while it runs.
#
# Modes:
#   (no args)  edge-detect: if admin was just lost, run the request. (LaunchAgent uses this.)
#   --now      run the request right now.
#   --dry      select the reason and screenshot the dialog, but DO NOT submit (safe test).
set -u

APP="/Applications/Privileges.app"
PROFILE="/Library/Managed Preferences/corp.sap.privileges.plist"
TARGET_REASON="Developer Requirement"
STATE_DIR="$HOME/Library/Application Support/privileges-rearm"
STATE="$STATE_DIR/last_state"
mkdir -p "$STATE_DIR"

# where the reason popup and the submit button sit, as fractions of the dialog
POPUP_XF="0.25"; POPUP_YF="0.488"
BUTTON_XF="0.50"; BUTTON_YF="0.78"

is_admin(){ dseditgroup -o checkmember -m "$(id -un)" admin >/dev/null 2>&1; }

# "X Y W H" (points) of the alert dialog: Privileges window, layer 0, taller than wide.
dialog_bounds(){
  osascript -l JavaScript <<'JXA'
ObjC.import('CoreGraphics'); ObjC.import('Foundation');
var a=ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(17,0)));
var w=a.filter(function(x){return (x.kCGWindowOwnerName||'').indexOf('Privileges')>=0 && x.kCGWindowLayer===0;})
       .map(function(x){return x.kCGWindowBounds;})
       .filter(function(b){return b.Height>b.Width;})
       .sort(function(p,q){return (q.Width*q.Height)-(p.Width*p.Height);});
w[0]?[Math.round(w[0].X),Math.round(w[0].Y),Math.round(w[0].Width),Math.round(w[0].Height)].join(' '):'';
JXA
}

# "X Y W H" of the open popup menu: Privileges window at the highest layer (>0).
menu_bounds(){
  osascript -l JavaScript <<'JXA'
ObjC.import('CoreGraphics'); ObjC.import('Foundation');
var a=ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(17,0)));
var w=a.filter(function(x){return (x.kCGWindowOwnerName||'').indexOf('Privileges')>=0 && x.kCGWindowLayer>0;})
       .sort(function(p,q){return q.kCGWindowLayer-p.kCGWindowLayer;});
var b=w[0]?w[0].kCGWindowBounds:null;
b?[Math.round(b.X),Math.round(b.Y),Math.round(b.Width),Math.round(b.Height)].join(' '):'';
JXA
}

# Synthetic left click at global point (x y).
click(){
  osascript -l JavaScript - "$1" "$2" <<'JXA'
function run(a){ ObjC.import('CoreGraphics'); ObjC.import('Foundation');
  var x=+a[0], y=+a[1];
  function post(t){ var e=$.CGEventCreateMouseEvent($(), t, $.CGPointMake(x,y), 0); $.CGEventPost(0,e); }
  post(5); post(1); $.NSThread.sleepForTimeInterval(0.06); post(2);   // move, down, up
}
JXA
}

# Print "INDEX COUNT": row index of the target reason and total menu rows
# (presets in profile order, then "Other..."). Falls back to 2 of 4.
reason_layout(){
  local i=0 v idx=-1
  while v=$(/usr/libexec/PlistBuddy -c "Print :ReasonPresetList:$i:default" "$PROFILE" 2>/dev/null); do
    [ "$v" = "$TARGET_REASON" ] && idx=$i
    i=$((i+1))
  done
  if [ "$i" -gt 0 ] && [ "$idx" -ge 0 ]; then echo "$idx $((i+1))"; else echo "2 4"; fi
}

do_request(){
  local dry="${1:-}"
  if is_admin; then echo "already admin — nothing to do"; return 0; fi

  open -a "$APP"
  local b="" i=0
  while [ "$i" -lt 30 ]; do b="$(dialog_bounds)"; [ -n "$b" ] && break; sleep 0.2; i=$((i+1)); done
  [ -z "$b" ] && { echo "request dialog did not appear"; return 1; }
  local X Y W H; read -r X Y W H <<< "$b"
  osascript -e 'tell application "Privileges" to activate' 2>/dev/null

  local IDX N; read -r IDX N <<< "$(reason_layout)"

  # open the reason dropdown
  click "$(awk "BEGIN{print $X+$W*$POPUP_XF}")" "$(awk "BEGIN{print $Y+$H*$POPUP_YF}")"
  # wait for the menu window, read its real frame, click the target row
  local mb="" j=0
  while [ "$j" -lt 15 ]; do mb="$(menu_bounds)"; [ -n "$mb" ] && break; sleep 0.1; j=$((j+1)); done
  if [ -z "$mb" ]; then echo "reason menu did not open"; return 1; fi
  local MX MY MW MH; read -r MX MY MW MH <<< "$mb"
  click "$(awk "BEGIN{print $MX+$MW*0.5}")" "$(awk "BEGIN{print $MY+$MH*(($IDX+0.5)/$N)}")"
  sleep 0.3

  if [ "$dry" = "--dry" ]; then
    screencapture -x -R"$X,$Y,$W,$H" "$STATE_DIR/last_dialog.png" 2>/dev/null
    kill "$(pgrep -f 'MacOS/Privileges$')" 2>/dev/null
    echo "dry run OK — '$TARGET_REASON' selected, NOT submitted. Screenshot: $STATE_DIR/last_dialog.png"
    return 0
  fi

  # click Request Privileges → the Touch ID sheet appears; you tap to finish.
  click "$(awk "BEGIN{print $X+$W*$BUTTON_XF}")" "$(awk "BEGIN{print $Y+$H*$BUTTON_YF}")"
  echo "submitted — authenticate with Touch ID to finish"
}

case "${1:-}" in
  --now) do_request ;;
  --dry) do_request --dry ;;
  *)
    now=standard; is_admin && now=admin
    prev=unknown; [ -f "$STATE" ] && prev="$(cat "$STATE")"
    printf '%s' "$now" > "$STATE"
    if [ "$prev" = "admin" ] && [ "$now" = "standard" ]; then do_request; fi
    ;;
esac
