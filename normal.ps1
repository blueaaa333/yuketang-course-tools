& {
    $ErrorActionPreference = 'Stop'
    $taskPython = Get-Command python -ErrorAction Stop
    $taskSource = @'
"""课件内嵌视频接口适配；按正常时间间隔提交事件，完成以服务端查询为准。"""
import asyncio
import math
import re
import secrets
import time
from urllib.parse import urlsplit, parse_qs
import httpx

def parse_url(raw):
    p = urlsplit(raw)
    if p.scheme != 'https' or not p.hostname or not (p.hostname == 'yuketang.cn' or p.hostname.endswith('.yuketang.cn')):
        raise ValueError('请输入雨课堂 HTTPS 地址')
    home = re.search(r'/studentLog/(\d+)/?$', p.path)
    if home:
        return p.hostname, int(home.group(1)), None
    m = re.search(r'/studentCards/(\d+)/(\d+)(?:/|$)', p.path)
    if m:
        classroom, cards = m.groups()
    else:
        m = re.search(r'/cards/detlist/(\d+)/?$', p.path)
        classroom = parse_qs(p.query).get('classroom_id', [''])[0]
        if not m or not classroom.isdigit():
            raise ValueError('请粘贴具体课件 studentCards 网址，或 cards/detlist 请求网址；也可填写 studentLog 课堂主页')
        cards = m.group(1)
    return p.hostname, int(classroom), cards

def videos_in(payload):
    result = []
    for slide in payload.get('Slides', []):
        for shape in slide.get('Shapes', []):
            uri = str(shape.get('URL', ''))
            if uri.startswith('rain://xtvideo/id/'):
                result.append({'slide': slide['PageIndex'], 'uri': uri,
                    'id': uri.rsplit('/', 1)[-1], 'title': shape.get('file_title', '未命名视频'), 'playurl': shape.get('playurl')})
    return result

def progress_in(payload, video):
    if payload.get('code') != 0:
        raise ValueError(f"进度查询失败：{payload.get('message')}")
    key = f"{video['slide']}:{video['id']}"
    return (payload.get('data') or {}).get(key) or payload.get(key) or {}

def done(progress):
    return progress.get('completed') in (1, True, '1')

def event(base, kind, position, seq):
    return dict(base, et=kind, cp=round(position, 1), sq=seq, ts=str(int(time.time()*1000)),
                d=0 if kind == 'loadstart' else base['d'])

def mp4_duration(data):
    start = 0
    while True:
        at = data.find(b'mvhd', start)
        if at < 4:
            return None
        start = at + 4
        size = int.from_bytes(data[at-4:at], 'big')
        body = data[at+4:at-4+size]
        if size < 32 or len(body) < 20 or body[1:4] != b'\0\0\0':
            continue
        version = body[0]
        if version == 0:
            scale = int.from_bytes(body[12:16], 'big')
            ticks = int.from_bytes(body[16:20], 'big')
            unknown = 2**32-1
        elif version == 1 and len(body) >= 32:
            scale = int.from_bytes(body[20:24], 'big')
            ticks = int.from_bytes(body[24:32], 'big')
            unknown = 2**64-1
        else:
            continue
        if scale and ticks not in (0, unknown):
            value = ticks / scale
            if math.isfinite(value) and 0 < value < 604800:
                return value

async def media_duration(url):
    parsed = urlsplit(url or '')
    if parsed.scheme != 'https' or not parsed.hostname or not (parsed.hostname == 'xuetangx.com' or parsed.hostname.endswith('.xuetangx.com')):
        raise ValueError('课件缺少受支持的视频地址')
    limit = 2 * 1024 * 1024
    # Separate client: never send account cookies to the media CDN.
    async with httpx.AsyncClient(timeout=30, follow_redirects=False) as media:
        for byte_range in (f'bytes=0-{limit-1}', f'bytes=-{limit}'):
            async with media.stream('GET', url, headers={'Range':byte_range}) as response:
                response.raise_for_status()
                data = bytearray()
                async for chunk in response.aiter_bytes(chunk_size=65536):
                    data.extend(chunk[:limit-len(data)])
                    if len(data) >= limit:
                        break
                duration = mp4_duration(bytes(data))
                if duration:
                    return duration
    raise ValueError('视频头尾未找到时长元数据，未提交该视频进度')

async def request_with_retry(client, method, path, **kwargs):
    for attempt in range(4):
        try:
            response = await client.request(method, path, **kwargs)
            response.raise_for_status()
            return response
        except (httpx.TransportError, httpx.HTTPStatusError) as exc:
            retryable = isinstance(exc, httpx.TransportError) or exc.response.status_code in (408, 429, 500, 502, 503, 504)
            if not retryable or attempt == 3:
                raise
            delay = 2 ** (attempt + 1)
            print(f'请求暂时失败：{type(exc).__name__}，{delay} 秒后重试（{attempt+1}/3）')
            await asyncio.sleep(delay)

def replay_streams(payload):
    if payload.get('code') != 0:
        raise ValueError(f"回放详情失败：{payload.get('code')} {payload.get('msg')}")
    data = payload.get('data') or {}
    live = [item for item in (data.get('live') or []) if isinstance(item, dict)]
    streams, seen = [], set()
    for item in live:
        ident = str(item.get('id') or '')
        raw_duration = item.get('duration')
        if not raw_duration and len(live) == 1:
            raw_duration = data.get('lessonDuration')
        duration = float(raw_duration or 0) / 1000
        if not ident or not math.isfinite(duration) or not 0 < duration < 604800:
            continue
        if ident in seen:
            continue
        seen.add(ident)
        streams.append((ident, duration))
    return streams

def replay_events(uid, cid, classroom, lesson, video, duration):
    end_ms = int(time.time()*1000)
    start_ms = end_ms - int(duration*1000) - 1500
    base = dict(i=20, p='web', t='ykt_playback', u=uid, c=str(cid),
        classroomid=str(classroom), lob='ykt', v=str(video), fp=0, tp=0, d=0,
        pg=f'{video}_{secrets.token_hex(4)}', n='ali-cdn.xuetangx.com',
        lesson_id=str(lesson), source='ks', sp=1)
    result = []
    for offset, kind in enumerate(('loadstart', 'loadeddata', 'play', 'playing', 'waiting', 'playing')):
        result.append(dict(base, et=kind, cp=0, ts=str(start_ms+offset*200), sq=len(result)+1))
    position = 0.0
    while position < duration:
        position = min(duration, position+5)
        result.append(dict(base, et='heartbeat', cp=round(position, 3),
            ts=str(start_ms+1400+int(position*1000)), sq=len(result)+1))
    return result

async def run():
    print('凭据输入可见；不要分享包含输入内容的截图。')
    raw = input('课堂或课件网址（自动遍历整门课）：').strip()
    host, classroom, cards = parse_url(raw)
    session = input('sessionid（可见）：').strip()
    csrf = input('csrftoken（可见）：').strip()
    xtbz = input('xtbz [ykt]：').strip() or 'ykt'
    if not session or not csrf:
        raise ValueError('凭据不能为空')
    async with httpx.AsyncClient(base_url=f'https://{host}', timeout=30,
            headers={'User-Agent':'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0', 'Referer':raw, 'X-Csrftoken':csrf, 'xtbz':xtbz, 'Sec-Fetch-Site':'same-origin', 'Sec-Fetch-Mode':'cors', 'Sec-Fetch-Dest':'empty'},
            cookies={'sessionid':session, 'csrftoken':csrf}) as client:
        async def get(path, **kwargs):
            r = await request_with_retry(client, 'GET', path, **kwargs)
            r.raise_for_status()
            return r.json()
        async def send(logs):
            r = await request_with_retry(client, 'POST', '/video-log/heartbeat/', json={'heart_data':logs})
            r.raise_for_status()
            answer = r.json()
            if isinstance(answer, dict) and (answer.get('code', 0) not in (0, None) or answer.get('errcode', 0) not in (0, None)):
                raise ValueError('上报接口返回错误，已停止')
        user = await get('/api/v3/user/basic-info')
        if user.get('code') != 0:
            raise ValueError(f"用户接口返回 code={user.get('code')}，msg={str(user.get('msg', user.get('message', '无错误说明')))[:160]}")
        if not isinstance(user.get('data'), dict) or 'id' not in user['data']:
            raise ValueError('用户接口返回成功，但 data 中缺少 id；这是响应结构不兼容，不应直接判断为 Cookie 错误')
        uid = user['data']['id']
        room = await get(f'/v2/api/web/classrooms/{classroom}', params={'role':5})
        if room.get('errcode', 0) != 0 or 'course_id' not in room.get('data', {}):
            raise ValueError('获取课堂失败')
        cid = room['data']['course_id']
        client.headers['Classroom-Id'] = str(classroom)
        university = room['data'].get('uv_id')
        if university:
            client.headers['University-Id'] = str(university)
            client.cookies.set('university_id', str(university))
            client.cookies.set('uv_id', str(university))
        activity_types = {}
        replay_submitted = 0
        replay_failed = 0
        entries = []
        seen = set()
        if cards:
            entries.append((cards, '输入的课件'))
            seen.add(cards)
        fingerprints = set()
        for page in range(1000):
            listing = await get(f'/v2/api/web/logs/learn/{classroom}', params={
                'actype':-1, 'page':page, 'offset':20, 'sort':-1})
            if listing.get('errcode') != 0:
                raise ValueError(f"课堂列表查询失败：{listing.get('errcode')} {listing.get('errmsg')}")
            activities = listing.get('data', {}).get('activities')
            if not isinstance(activities, list):
                raise ValueError('课堂列表 activities 结构不兼容，未将本次结果判定为整课完成')
            if not activities:
                break
            fingerprint = repr(activities)
            if fingerprint in fingerprints:
                raise ValueError('课堂列表分页重复，已停止，避免漏掉课件却误报整课完成')
            fingerprints.add(fingerprint)
            for activity in activities:
                ident = activity.get('courseware_id')
                if ident is None:
                    continue
                ident = str(ident)
                if ident.isdigit():
                    activity_types[ident] = str(activity.get('type', ''))
                if ident.isdigit() and ident not in seen:
                    entries.append((ident, activity.get('title') or f'活动 {ident}'))
                    seen.add(ident)
            if len(activities) < 20:
                break
        else:
            raise ValueError('课堂列表超过分页限制，未开始提交')
        if not entries:
            raise ValueError('课堂列表未识别到 courseware_id。需检查列表响应，不代表整门课没有视频。')
        print(f'找到 {len(entries)} 个活动候选，逐项检查课件内嵌视频。')
        unfinished = 0
        video_count = 0
        unsupported = 0
        for index, (cards, title) in enumerate(entries, 1):
            print(f'\n[{index}/{len(entries)}] {title}，课件编号 {cards}')
            if activity_types.get(cards) == '14':
                try:
                    referer = f'https://{host}/v2/web/v3/playback/{cards}/slide/2/0'
                    summary = await get('/api/v3/lesson-summary/replay',
                        params={'lesson_id':cards}, headers={'Referer':referer})
                    streams = replay_streams(summary)
                    if not streams:
                        replay_failed += 1
                        print('回放未提供有效视频编号和时长，未提交。')
                        continue
                    for replay_id, replay_duration in streams:
                        events = replay_events(uid, cid, classroom, cards, replay_id, replay_duration)
                        print(f'直播回放 {replay_id}，时长 {replay_duration:.1f} 秒')
                        previous_position = 0.0
                        for seq, packet in enumerate(events, 1):
                            delay = max(0, packet['cp']-previous_position)
                            if delay:
                                await asyncio.sleep(delay)
                            packet['ts'] = str(int(time.time()*1000))
                            await send([packet])
                            previous_position = packet['cp']
                            if seq % 12 == 0:
                                print(f"回放已提交位置 {packet['cp']:.1f}/{replay_duration:.1f} 秒（未确认完成）")
                        replay_submitted += 1
                        print('回放事件已提交；尚无已验证的回放进度查询接口，不计入确认完成，请在网页核对。')
                except (ValueError, httpx.HTTPError) as exc:
                    replay_failed += 1
                    print(f'回放未处理：{type(exc).__name__}：{exc}')
                continue
            try:
                payload = await get(f'/v2/api/web/cards/detlist/{cards}', params={'classroom_id':classroom})
            except httpx.HTTPStatusError as exc:
                if exc.response.status_code in (400, 404):
                    unsupported += 1
                    print('该活动不适用课件详情接口，跳过；不判定为已完成。')
                    continue
                raise
            if payload.get('errcode') != 0:
                unsupported += 1
                print(f"未读取活动：{payload.get('errcode')} {payload.get('errmsg')}；不判定为完成。")
                continue
            videos = videos_in(payload.get('data', {}))
            if not videos:
                unsupported += 1
                print('该活动未识别到内嵌视频；本活动没有内嵌视频；普通阅读和作业尚未适配。')
                continue
            video_count += len(videos)
            print(f'识别到 {len(videos)} 个视频；Ctrl+C 停止，重启会查询已保存的进度。')
            for v in videos:
                params = dict(user_id=uid, cid=cid, vtype='rate', video_type='ykt_cards',
                    classroom_id=classroom, cards_id=cards, v_url=v['uri'], slide=v['slide'])
                async def progress():
                    return progress_in(await get('/video-log/get_video_watch_progress/', params=params), v)
                current = await progress()
                if done(current):
                    print(f"跳过已完成：{v['title']}")
                    continue
                duration = float(current.get('video_length') or 0)
                if not math.isfinite(duration) or duration <= 0:
                    print(f"读取视频元数据：{v['title']}")
                    try:
                        duration = await media_duration(v.get('playurl'))
                        print(f"视频元数据时长：{duration:.1f} 秒")
                    except (ValueError, httpx.HTTPError) as exc:
                        print(f"未处理：{v['title']}；{exc}")
                        unfinished += 1
                        continue
                position = min(duration, max(0, float(current.get('last_point') or 0)))
                if not math.isfinite(position):
                    raise ValueError('接口返回无效播放位置')
                base = dict(i=5, p='web', n='ali-cdn.xuetangx.com', lob='ykt', fp=0,
                    tp=position, sp=1, u=uid, uip='', c=cid, v=cards, skuid='',
                    classroomid=classroom, cc='', d=duration, pg=f'{cards}_{secrets.token_hex(3)}',
                    t='ykt_cards', cards_id=cards, slide=v['slide'], v_url=v['uri'])
                seq = 0
                for kind in ('loadstart', 'seeking', 'loadeddata', 'play', 'playing'):
                    seq += 1
                    await send([event(base, kind, position, seq)])
                print(f"开始：{v['title']}，位置 {position:.1f}/{duration:.1f} 秒")
                while position < duration:
                    step = min(5, duration-position)
                    await asyncio.sleep(step)
                    position = min(duration, position+step)
                    seq += 1
                    await send([event(base, 'heartbeat', position, seq)])
                    if seq % 12 == 0:
                        p = await progress()
                        print(f"  服务端进度：{float(p.get('rate') or 0):.0%}")
                        if done(p):
                            break
                        if seq >= 29 and float(p.get('rate') or 0) <= float(current.get('rate') or 0):
                            raise ValueError('提交约两分钟后服务器进度仍未增长，已停止；不能判定此方法有效')
                seq += 1
                await send([event(base, 'pause', position, seq), event(base, 'videoend', position, seq+1)])
                await asyncio.sleep(3)
                final = await progress()
                if done(final):
                    print(f"服务端确认完成：{v['title']}")
                else:
                    unfinished += 1
                    print(f"服务端未确认完成：{v['title']}，进度 {float(final.get('rate') or 0):.0%}；不自动重复提交。")

        print(f'整课遍历结束：识别 {video_count} 个内嵌视频；未确认完成 {unfinished} 个；未支持或未读取活动 {unsupported} 个。普通阅读未处理。')

        print(f'直播回放：已提交但待网页核对 {replay_submitted} 个；未处理或失败 {replay_failed} 个。普通阅读未提交。')

if __name__ == '__main__':
    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        print('\n已停止。')
    except Exception as exc:
        print(f'运行失败：{type(exc).__name__}：{str(exc) or repr(exc)}')
        print('可重新运行相同命令：会查询服务器进度，跳过已完成视频，并从已记录的位置继续。')
        raise SystemExit(1)

'@
    $taskScriptPath = Join-Path ([IO.Path]::GetTempPath()) ('yuketang_course_' + [guid]::NewGuid().ToString('N') + '.py')
    try {
        [IO.File]::WriteAllText($taskScriptPath, $taskSource, [Text.UTF8Encoding]::new($false))
        & $taskPython.Source $taskScriptPath
        if ($LASTEXITCODE -ne 0) { Write-Warning ('Script exited with code ' + $LASTEXITCODE) }
    }
    finally {
        if (Test-Path -LiteralPath $taskScriptPath) {
            Remove-Item -LiteralPath $taskScriptPath -Force
        }
    }
}
