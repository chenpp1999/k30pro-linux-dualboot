#!/bin/sh
# SPDX-License-Identifier: MIT
# lmi-dashboard.cgi - busybox httpd CGI that renders /run/lmi-monitor/latest
# plus the recent monitor history.  LAN-only (no auth, no TLS): the USB NCM
# network (172.16.42.1) and the local WiFi are the intended audience.
echo "Content-Type: text/html; charset=utf-8"
echo
cat <<'EOF'
<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="30">
<title>lmi server</title>
<style>
body{background:#111;color:#ddd;font:14px/1.45 monospace;margin:1rem}
h1{font-size:1.1rem;color:#8fd} table{border-collapse:collapse;margin:.6rem 0}
td,th{border:1px solid #333;padding:.2rem .6rem;text-align:left}
th{background:#1b1b1b;color:#9cf} .k{color:#8cf} .warn{color:#f96}
</style></head><body>
<h1>lmi server status</h1>
EOF

if [ -r /run/lmi-monitor/latest ]; then
	echo '<table>'
	sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' /run/lmi-monitor/latest |
		while IFS='=' read -r k v; do
			printf '<tr><th>%s</th><td>%s</td></tr>\n' "$k" "$v"
		done
	echo '</table>'
else
	echo '<p class="warn">monitor not running (/run/lmi-monitor/latest missing)</p>'
fi

if [ -r /run/lmi-chargectl.state ]; then
	echo '<h1>charge control</h1><table>'
	sed -e 's/&/\&amp;/g' /run/lmi-chargectl.state |
		while IFS='=' read -r k v; do
			printf '<tr><th>%s</th><td>%s</td></tr>\n' "$k" "$v"
		done
	echo '</table>'
fi

d=$(date -u '+%Y-%m-%d')
if [ -r "/var/log/lmi-monitor/$d.csv" ]; then
	echo "<h1>today ($d)</h1><table><tr><th>rows</th><td>"
	wc -l < "/var/log/lmi-monitor/$d.csv" | tr -d ' '
	echo "</td></tr></table><pre>"
	tail -n 20 "/var/log/lmi-monitor/$d.csv" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g'
	echo '</pre>'
fi
echo '<p><a href="/cgi-bin/lmi-dashboard.cgi">refresh</a></p></body></html>'
