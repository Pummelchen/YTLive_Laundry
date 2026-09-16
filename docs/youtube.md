# YouTube

## The YouTube API  (bin/yt_api.py)
The only thing that can create a broadcast. Stdlib only, no pip installs.

    bin/yt_api.py auth          one-time: OAuth device flow -> conf/yt_oauth.json
    bin/yt_api.py status        what is live right now, as JSON
    bin/yt_api.py prepare       create + bind a broadcast, ready for ingest to start it
    bin/yt_api.py ensure-live   idempotent: if nothing is live, create + bind + go live
    bin/yt_api.py end           end the active broadcast so YouTube saves the VOD
    bin/yt_api.py token         can this installation still talk to YouTube? Probes the
                                credential (real refresh attempt) -> JSON "probe":
                                LIVE|DEAD|UNKNOWN. Exit 0 fine / 1 expiring / 2 dead|unknown.
    bin/yt_api.py token --offline   network-free countdown only, never authoritative
    bin/yt_api.py capture [id]  snapshot the configuration into the reference
    bin/yt_api.py verify [id]   compare a broadcast against the reference (0 match, 1 drift)
    bin/yt_api.py enforce [id]  apply the reference and retry until it matches
    bin/yt_api.py thumbnail [f] adopt a file as the golden thumbnail, or re-apply it
    bin/yt_api.py thumbnail --check   is the live thumbnail actually ours?

One-time setup: console.cloud.google.com/apis/credentials -> enable "YouTube Data API v3"
-> Create OAuth client ID -> type **TVs and Limited Input devices** -> run `bin/yt_api.py
auth` and paste the id and secret. It prints a short code to enter at google.com/device.
No browser is needed on the streaming Mac, so this works fine over SSH.

**The 7-day expiry is a "Testing" behaviour, not a fact of life.** A refresh token issued
to an External OAuth app whose publishing status is "Testing" dies after 7 days. Publishing
the app to **"In production"** removes that clock. Google verification is NOT required to
escape it: an unverified published app still works for its owner - you click past one
"Google hasn't verified this app -> Advanced -> Go to <app> (unsafe)" screen - and a
100-user cap applies. Approval is only needed to remove that warning for *other* users.

    console.cloud.google.com -> APIs & Services -> OAuth consent screen (Google Auth
    Platform) -> Audience -> User type: External -> Publishing status: "In production"
    -> Publish app
    Keep the existing "TVs and Limited Input devices" client. Do NOT submit for
    verification. Then re-run: bin/yt_api.py auth
    Tokens issued while the app was Testing keep their 7-day life, so publishing without a
    fresh auth changes nothing.

`bin/yt_api.py auth` prints this same advice at its step 4, so the operator sees it at the
moment it matters.

This installation is deliberately hardened for the case where the owner cannot publish, so
a dead token cannot silently take the channel dark:

    bin/yt_api.py token       PROBES the credential (probe_refresh_token: a real refresh
                              attempt, JSON "probe": LIVE|DEAD|UNKNOWN) instead of trusting
                              a day countdown. 0 = fine, 1 = expiring, 2 = dead or unknown.
    bin/yt_api.py token --offline   keeps the old network-free countdown behaviour; it can
                              only predict, so it is never authoritative. `bin/status.sh
                              --no-net` passes this flag explicitly, so a no-network health
                              check still gets the countdown and is told it is not the probe.
    YT_TOKEN_TTL_DAYS         the countdown is now ADVISORY only and 0 silences it. An
                              elapsed countdown on a token Google still accepts is reported
                              as noise from a published app, not as an outage.
    status.sh                 shows the probe result every time you look
    yt_monitor.sh             re-checks every TOKEN_CHECK_EVERY (6h) and logs a loud
                              warning; stream.sh logs it at every rotation

The countdown existed before but was written into a variable the rotation preflight threw
away, so it reached no log at all. Now it reaches three.

**A dead token no longer cuts the stream into the dark.** `stream.sh`'s `rotate_broadcast()`
checks the API before cutting: if it cannot create the successor it REFUSES the rotation and
stays LIVE. The segment then runs past 12h and is not archived, but a lost recording beats a
dark channel, which needs a human either way. `ROTATE_WITHOUT_API="no"` is the default;
`yes` restores the old cut-anyway behaviour. `ROTATE_API_RETRY` (900s) sets the re-check
deadline so a refused cut is not retried every 5 seconds.

**Verified end to end on 2026-09-05 15:01-15:03** - a forced rotation ran the whole path:

    15:01:54  ROTATE (manual): stopping ingest, closing dcw5E1qrp8I
    15:01:56  ending broadcast via API: {"status":"ENDED","broadcast_id":"dcw5E1qrp8I"}
    15:02:15  YouTube state=offline after 15s
    15:03:22  publisher back up
    15:03:46  LIVE: broadcast is up via API: tzlsZ_Nv6VE

110s of downtime, old broadcast saved as a 41:42 VOD, new one live with a new URL. Note
"offline after 15s" - a real confirmation from YouTube, where the pre-API code always
printed "0s" because it could not tell "offline" from "the lookup failed".

Everything switches on automatically once `conf/yt_oauth.json` exists:
- **stream.sh** calls `prepare_broadcast()` inside `start_publisher()`, so `prepare` runs on
  every publisher start (cold start, watchdog restart, rotation) and creates+binds the next
  broadcast BEFORE ffmpeg pushes. It calls `end` only as a fallback, when YouTube has not
  closed the outgoing broadcast within `ROTATE_END_PATIENCE` (autoStop normally does it).
- **yt_monitor.sh** calls `ensure-live` first when it sees the channel OFFLINE, and only asks
  stream.sh for a rotation as a fallback if the API cannot bring it live.
- **ensure-live reuses a broadcast it already created** rather than minting a new one on
  every retry, and deletes the abandoned ones. Without that, a spell of "channel dark and
  ingest broken" left a fresh orphaned broadcast on the channel every retry, at 100 quota
  units each. It only ever touches broadcasts bound to our own stream key - a broadcast
  scheduled by hand in Studio is left alone.
Without the file the stream still runs and the current segment is still saved (YouTube's
autoStop closes it when ingest stops), but nothing can create a successor: `prepare_broadcast`
logs that the channel will go dark at the next cut, `rotate_broadcast` refuses to cut at all
unless `ROTATE_WITHOUT_API=yes`, and the monitor asks for a rotation it cannot satisfy. Only
`bin/yt_api.py auth` recovers it.

`enableAutoStart: true` on the created broadcast is what puts it live as soon as ingest
ARRIVES at the stream it is ALREADY BOUND to. It does not create a broadcast, so it cannot
help when ingest arrives at a bare stream key - that is what `prepare` is for.
`enableAutoStop: true` is forced on too: stopping ingest makes YouTube close and archive the
broadcast by itself (measured ~9s), which is the half of the rotation that needs no API.

Set YT_TITLE_FMT in conf/stream.env or every rotation loses the channel's hashtags -
conf/stream.env is *sourced*, not exported, so stream.sh passes it through explicitly via
yt_api_call(). YT_PRIVACY defaults to public.

conf/yt_oauth.json is gitignored even though the repo is public: a refresh token grants
ongoing control of the channel and would outlive any later decision to change that.
conf/stream.env is gitignored for the same reason - it holds the stream key.

## The token is not optional  (2026-09-07)
There was a `native_is_proven()` flag that watched the rotation history and, after three
consecutive "native" rotations, stopped warning that the OAuth token was expiring - on the
theory that the API had become a spare wheel.

It was wrong and has been removed. `mode=native` only ever meant "went live without needing
the `ensure-live` fallback". Every rotation still calls the API through `prepare` to create
and bind the next broadcast, so with no token there is no rotation at all. The flag went
green on 2026-09-07 and would have suppressed the expiry warning three days before the
token died on the 12th.

Why "native" cannot mean "no API needed": YouTube retired automatic/default broadcast
creation in 2020
(developers.google.com/youtube/v3/live/guides/migration-guide-default-broadcasts). Pushing
RTMP at a bare stream key does nothing; with no broadcast bound, `enableAutoStart` has
nothing to start. Measured here 2026-09-05: six minutes of clean ingest against a dark
channel produced nothing. What YouTube DOES handle with no API is the other end of the cut -
`enableAutoStop` closes and archives the broadcast when ingest stops (~9s measured) - so a
dead token still saves the CURRENT segment's VOD; it just cannot create the next broadcast,
and the channel goes dark until a human runs `bin/yt_api.py auth`. That is the documented
2026-09-05 five-hour outage.

A green light saying a dependency is optional, when it is not, is worse than no light.
status.sh now states plainly that the API is required for every rotation.

## Broadcast configuration  (added 2026-09-06)
Every rotation makes a NEW video, and a new video inherits almost nothing. Description,
category and language happen to come across because they are channel default-upload
settings. **Tags do not** - and here that is 38 local search terms doing the discovery
work, which were being silently dropped three times a day and expected to be retyped in
Studio by hand.

`conf/broadcast_template.json` is the reference: title, description, tags, categoryId,
language, privacy, license, embeddable, DVR, latency, and the thumbnail. At every rotation
stream.sh captures from the OUTGOING broadcast and enforces the reference onto the new one,
so anything edited in Studio propagates forward by itself.

    bin/yt_api.py capture     # adopt what is live now as the reference
    bin/yt_api.py verify      # 0 = matches, 1 = drifted (names what differs)
    bin/yt_api.py enforce     # fix it, retrying until it matches

stream.sh re-checks every ENFORCE_EVERY (30 min) and repairs drift. Cheap when nothing is
wrong: one videos.list, and an update only when something actually moved.

Five things this needed in order to work rather than merely appear to:

**capture MERGES, it does not replace.** A field the source lacks keeps whatever the
reference already had. Without that, the first capture from a freshly created broadcast -
which has no tags yet - records "no tags" and destroys them permanently.

**enforce judges by the WRITE RESPONSE, not by re-reading.** videos.list is eventually
consistent and serves stale data for a surprisingly long time; a read-back loop reported
"tags(1 vs 38)" three times over for a write that had already succeeded, and fired three
redundant updates chasing it.

**The reference owns the title, not conf/stream.env.** YT_TITLE_FMT was overwriting a
"#indonesia" added in Studio at every enforcement. Requiring stream.env to be edited in
lockstep just relocates the manual work. capture refuses to adopt a dated fallback title,
which is what made an explicit override seem necessary in the first place.

**localizations are not compared.** With defaultLanguage set, YouTube mirrors the main
snippet into that localization itself and lags doing it, so comparing them reported drift
permanently and would have fired a pointless update every 30 minutes forever.

**The drift log names the tags it adds and removes.** It used to print counts, so a tag
added in Studio was removed by enforcement with no record of which one - and that is not
recoverable from YouTube afterwards.

### Editing settings in Studio
The drift check will treat a Studio edit as drift and revert it if the reference still
holds the old value. Before editing, move the reference aside:

    mv conf/broadcast_template.json conf/broadcast_template.json.held   # enforcement OFF
    # ... edit in Studio, wait for it to appear (the API lags, sometimes by many minutes)
    cp conf/broadcast_template.json.held conf/broadcast_template.json
    bin/yt_api.py capture                                              # adopt the change

Both `apply_settings` and `enforce_drift` guard on that file existing, so moving it
disables enforcement instantly with no restart and no write to YouTube.

## Thumbnail
`conf/thumbnail.jpg` is re-applied and verified at every rotation. It is checked against
**YouTube's render of it**, not against the source file: a 4:3 source comes back as a 16:9
render with the sides filled, which correlates at ~0.5 against the original no matter how
correct it is. conf/thumbnail_rendered.jpg is that baseline; comparing render to render is
like for like and scores 1.0.

    bin/yt_api.py thumbnail path/to/image.jpg   # adopt and apply
    bin/yt_api.py thumbnail --check             # is the live one ours?

The current still is the shop entrance rotated 3 degrees left and cropped to fill 16:9.
Rotate first, crop second: a 3 degree rotation leaves empty wedges at the edges, so the crop
has to clear those as well as the 4:3 letterbox. For a 1280x960 source the safe inner box is
1180x826 and the 16:9 crop taken from it is 1180x664, scaled to 1280x720. ffmpeg's rotate
filter takes a positive angle as CLOCKWISE, so "3 degrees left" is `rotate=-3*PI/180`.

Cropping to fill is only safe when the source has nothing in the corners. The previous
branded still had text in two corners and had to be pillarboxed instead.

There is no local file-size check. YouTube documents a 2 MB limit but does not enforce it -
a 2.29 MB PNG uploaded fine. Refusing a file the service would accept is not validation.

## Suggested thumbnail for the finished video  (added 2026-09-07)
**YouTube SOMETIMES throws the thumbnail away when a broadcast becomes a video**, falling
back to a frame of its own choosing - which is why Studio then offers "pick one of 3".
It is not consistent, and both outcomes have been observed:

    ufmT_Fjg9aw   lost it   maxresdefault was byte-identical to YouTube's own maxres1,
                            despite the branded thumbnail having been enforced for the
                            whole eight hours it was live
    2LAqYoT1vMU   kept it   maxresdefault correlates +1.000 with conf/thumbnail.jpg and
                            only +0.16 with any of the three suggestions

The difference appears to be how recently the thumbnail was set before the cut - the one
that survived had been re-applied ten minutes earlier by a publisher restart, the one that
did not had last been set eight hours before. That is a plausible explanation from two data
points, not a proven rule, so the code does not rely on it: it checks what the video
actually has and acts accordingly.

The three suggestions are fetchable at predictable URLs. `1/2/3.jpg` are only 120x90, far
under the 640x360 minimum for an upload - but `maxres1/2/3.jpg` are the same frames at
1280x720, exactly the recommended size. Uploading maxres1 back through thumbnails.set turns
the auto-pick into a real custom thumbnail.

    bin/yt_api.py pick-thumbnail <videoId> [1|2|3] [--force]

It refuses only when the video has a DELIBERATELY CHOSEN thumbnail. Two things count as
"still the default" and are replaced:

    byte-identical to one of the three suggestions   YouTube's auto-pick
    visually identical to conf/thumbnail.jpg          our branded still

The second one matters and was originally missing. conf/thumbnail.jpg is the same image on
every video - it is the default, and replacing it with a frame from that video's own
content is the entire point. Treating it as a deliberate choice meant two finished streams
kept an identical generic still while a third correctly showed its own footage.

stream.sh schedules this at every cut for the outgoing video, THUMB_DELAY (1h) later, via
log/thumb_pending rather than a sleeping subshell so it survives a restart. The file is
OVERWRITTEN at each cut, so only ever the most recent video is pending - there is no queue.
A video still processing returns NOTREADY and is retried every THUMB_RETRY (15 min) up to
THUMB_MAX_TRIES (8), then given up on rather than retried forever.

## Dual stream
Soft issue, not chased. No field for it exists anywhere in youtube/v3 - checked against the
discovery document and every part of the liveBroadcasts and liveStreams resources - so it
can be neither set nor read here. It is also only toggleable while a stream is in its
starting phase, not once running, which on an 8h rotation is a few unattended minutes per
cycle. Recorded under "manual" in the reference and reported by status.sh as a single quiet
line. Treat it as off.
