#!/usr/bin/env python3
"""Read/set the ONVIF video encoder config on the camera.
  cam_config.py get
  cam_config.py set <token> <fps> <bitrate_kbps> <quality> <govlength>
"""
import urllib.request, re, sys
HOST, PORT = "192.168.1.2", "8899"
MEDIA = f"http://{HOST}:{PORT}/onvif/media_service"

def call(action, body):
    env = ('<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body '
           'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" '
           'xmlns:tt="http://www.onvif.org/ver10/schema">' + body + '</s:Body></s:Envelope>')
    r = urllib.request.Request(MEDIA, data=env.encode(),
        headers={"Content-Type": f'application/soap+xml; charset=utf-8; action="{action}"'})
    try:
        return urllib.request.urlopen(r, timeout=10).read().decode('utf-8', 'replace')
    except Exception as e:
        return "__ERR__ " + str(e) + "\n" + (e.read().decode('utf-8','replace')[:600] if hasattr(e,'read') else '')

def get():
    return call("http://www.onvif.org/ver10/media/wsdl/GetVideoEncoderConfigurations",
                "<trt:GetVideoEncoderConfigurations/>")

def show(x):
    for b in re.findall(r'<trt:Configurations.*?</trt:Configurations>', x, re.S):
        g=lambda t: (re.search(rf'<tt:{t}>(.*?)</tt:{t}>', b, re.S).group(1) if re.search(rf'<tt:{t}>(.*?)</tt:{t}>', b, re.S) else '?')
        tok=re.search(r'token="([^"]+)"', b)
        print(f"  {tok.group(1) if tok else '?'}: {g('Width')}x{g('Height')} fps={g('FrameRateLimit')} "
              f"interval={g('EncodingInterval')} bitrate={g('BitrateLimit')}kbps quality={g('Quality')} gov={g('GovLength')}")

if sys.argv[1] == "get":
    x = get()
    if "__ERR__" in x: print(x[:300]); sys.exit(1)
    show(x)
elif sys.argv[1] == "set":
    tok, fps, br, q, gov = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
    x = get()
    blk = [b for b in re.findall(r'<trt:Configurations.*?</trt:Configurations>', x, re.S) if f'token="{tok}"' in b]
    if not blk: sys.exit(f"token {tok} not found")
    b = blk[0]
    w = re.search(r'<tt:Width>(\d+)</tt:Width>', b).group(1)
    h = re.search(r'<tt:Height>(\d+)</tt:Height>', b).group(1)
    prof = re.search(r'<tt:H264Profile>(.*?)</tt:H264Profile>', b).group(1)
    body = (f'<trt:SetVideoEncoderConfiguration><trt:Configuration token="{tok}">'
            f'<tt:Name>{tok}</tt:Name><tt:UseCount>1</tt:UseCount><tt:Encoding>H264</tt:Encoding>'
            f'<tt:Resolution><tt:Width>{w}</tt:Width><tt:Height>{h}</tt:Height></tt:Resolution>'
            f'<tt:Quality>{q}</tt:Quality>'
            f'<tt:RateControl><tt:FrameRateLimit>{fps}</tt:FrameRateLimit>'
            f'<tt:EncodingInterval>1</tt:EncodingInterval><tt:BitrateLimit>{br}</tt:BitrateLimit></tt:RateControl>'
            f'<tt:H264><tt:GovLength>{gov}</tt:GovLength><tt:H264Profile>{prof}</tt:H264Profile></tt:H264>'
            f'<tt:Multicast><tt:Address><tt:Type>IPv4</tt:Type><tt:IPv4Address>239.0.1.0</tt:IPv4Address></tt:Address>'
            f'<tt:Port>32002</tt:Port><tt:TTL>2</tt:TTL><tt:AutoStart>false</tt:AutoStart></tt:Multicast>'
            f'<tt:SessionTimeout>PT10S</tt:SessionTimeout>'
            f'</trt:Configuration><trt:ForcePersistence>true</trt:ForcePersistence></trt:SetVideoEncoderConfiguration>')
    r = call("http://www.onvif.org/ver10/media/wsdl/SetVideoEncoderConfiguration", body)
    print("  result:", "OK" if "SetVideoEncoderConfigurationResponse" in r else r[:400])
