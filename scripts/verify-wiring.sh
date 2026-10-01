#!/usr/bin/env bash
set -uo pipefail
BASE_URL="https://$(cat ~/.privacypi-host)"
: "${PRIVACYPI_ADMIN_PASS:?export PRIVACYPI_ADMIN_PASS (admin UI password)}"
: "${PRIVACYPI_TOTP_SECRET:?export PRIVACYPI_TOTP_SECRET (admin TOTP base32 secret)}"

python3 -c "
import urllib3; urllib3.disable_warnings()
import requests, re, pyotp, sys, io
s = requests.Session(); s.verify = False
BASE = '$BASE_URL'
HDR = {'Referer': f'{BASE}/'}
csrf = re.search(r'csrf_token\" value=\"([^\"]+)\"', s.get(f'{BASE}/login').text).group(1)
s.post(f'{BASE}/login', data={'csrf_token':csrf,'username':'admin','password':'$PRIVACYPI_ADMIN_PASS'}, headers=HDR, allow_redirects=False)
csrf = re.search(r'csrf_token\" value=\"([^\"]+)\"', s.get(f'{BASE}/2fa').text).group(1)
totp = pyotp.TOTP('$PRIVACYPI_TOTP_SECRET').now()
s.post(f'{BASE}/2fa', data={'csrf_token':csrf,'code':totp}, headers=HDR, allow_redirects=False)
csrf2 = re.search(r'csrf-token\" content=\"([^\"]+)\"', s.get(f'{BASE}/').text).group(1)

passes = 0; fails = 0
def check(desc, cond):
    global passes, fails
    print(f'  {\"✓\" if cond else \"✗\"} {desc}')
    passes += int(cond); fails += int(not cond)

print()
print('[ VPN wiring ]')
fd = {'username':'testuser','password':'testpass'}
r = s.post(f'{BASE}/api/vpn/mullvad/credentials', data=fd, headers={'X-CSRFToken':csrf2,'Referer':f'{BASE}/vpn'})
check('mullvad creds POST returns ok', r.json().get('ok'))

# Upload a fake .ovpn
files = {'file': ('test.ovpn', b'remote vpn.example.com 1194\nclient\ndev tun\n', 'text/plain')}
r = s.post(f'{BASE}/api/vpn/mullvad/upload', files=files, headers={'X-CSRFToken':csrf2,'Referer':f'{BASE}/vpn'})
check('mullvad .ovpn upload returns ok', r.json().get('ok'))

print()
print('[ DNS wiring ]')
r = s.post(f'{BASE}/api/dns/profile', data={'profile':'Strict'}, headers={'X-CSRFToken':csrf2,'Referer':f'{BASE}/dns'})
check('DNS profile set to Strict', r.json().get('ok') and r.json().get('profile') == 'Strict')

print()
print('[ Password change ]')
# Wrong current → reject
r = s.post(f'{BASE}/api/password', data={'current':'wrong','new':'Unused-New-Pass-1234-x','new2':'Unused-New-Pass-1234-x'}, headers={'X-CSRFToken':csrf2,'Referer':f'{BASE}/system'})
check('wrong current pw rejected', not r.json().get('ok'))

print()
print('[ System actions ]')
# restart-flask is allowed (don't actually run reboot/factory-reset in test)
# Just check the endpoint exists and validates the action
r = s.post(f'{BASE}/api/system/invalid-action', headers={'X-CSRFToken':csrf2,'Referer':f'{BASE}/system'})
check('invalid system action returns 400', r.status_code == 400)

print(f'\n==> Result: {passes} passed, {fails} failed')
sys.exit(0 if fails == 0 else 1)
"
