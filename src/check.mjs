#!/usr/bin/env node
// 치지직 방송 점검 도구 (제보·신고 근거 수집용). 한 번 실행하고 끝난다. 상시 프로세스 없음.
//
//   node check.mjs <채널ID 또는 방송 주소> [...]    그 방송을 지금 점검하고 증거 저장
//   node check.mjs scan [--min 10] [--max 100] [--limit 30] [--category 오버워치]
//                                                   방송 목록을 훑어 의심 신호가 있는 방송 찾기
//   node check.mjs watch <채널> [--interval 30]     지켜보기: 멈출 때까지 일정 간격으로 시청자수 기록
//   node check.mjs pattern <채널>                   지금까지 쌓인 기록으로 방송별 반복 패턴 요약
//   node check.mjs demo                             실제 채널이 아닌 예시 데이터 (화면 둘러보기용, 저장 안 함)
//   node check.mjs selftest                         판정 로직 자체 점검
//   --json 을 붙이면 한 줄에 JSON 하나씩 출력 (맥 앱 '치지직 점검.app' 이 이 출력을 읽는다)
//
// 결과: 증거/<채널>/<시각>/ 에 요약.txt, 원본.json, 화면.jpg / 점검기록.tsv 에 한 줄씩 누적
// 의심 신호는 판정 기준을 넘었다는 뜻일 뿐, 조작을 확정하지 않는다.
import assert from 'node:assert';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// 증거와 점검기록을 쌓는 폴더. 맥 앱은 CHZZK_CHECK_DIR 로 지정하고, 직접 실행하면 이 파일이 있는 폴더.
const BASE = process.env.CHZZK_CHECK_DIR || path.dirname(fileURLToPath(import.meta.url));
const HISTORY = path.join(BASE, '점검기록.tsv');
const WATCH_DIR = path.join(BASE, '지켜보기');
const API = 'https://api.chzzk.naver.com';
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36';

// 판정 기준. 실제 방송 몇 곳에서 채팅방 접속 인원은 시청자수의 1.1~1.9배였다(2026-11-20 표본).
const T = {
    minViewers: 20,      // 이보다 적으면 비율 신호는 내지 않음 (작은 숫자는 우연이 큼)
    chatRoomRatio: 0.6,  // 채팅방 접속 인원이 시청자수의 이 비율 미만이면 신호
    silenceMin: 30,      // 이 시간(분) 동안 채팅이 없으면 신호
    jumpAbs: 10,         // 급증: 이 인원 이상,
    jumpRatio: 1.3,      //       그리고 이 배수 이상 늘어야 함
    jumpWindowMin: 10,   // 급증 비교 구간(분). 바로 앞 채팅과는 항상 비교
    startGraceMin: 15,   // 방송 시작 직후(분)는 사람이 몰려드는 게 정상이라 급증으로 보지 않음
    vodRatio: 2,         // 시청자수가 다시보기 조회수 중앙값의 이 배수 이상이면 참고 신호
    followerRatio: 0.1,  // 시청자수가 팔로워의 이 비율을 넘으면 참고 신호
    prevRatio: 1.5,      // 직전 점검 대비 이 배수 이상(그리고 jumpAbs 이상) 늘면 신호
    fewChatters: 3,      // 최근 채팅 20개 이상이 이 개수 이하의 계정에서만 나오고
    fewChattersViewers: 50, // 시청자가 이 이상이면 참고 신호
};

const argv = process.argv.slice(2);
const JSON_OUT = argv.includes('--json');
const args = argv.filter((x) => x !== '--json');
const emit = (o) => { if (JSON_OUT) console.log(JSON.stringify(o)); };
const say = (...x) => { if (!JSON_OUT) console.log(...x); };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const full = (ms) => new Date(ms).toLocaleString('sv-SE');
const hm = (ms) => new Date(ms).toLocaleTimeString('sv-SE').slice(0, 5);
const clean = (s) => String(s ?? '').replace(/[\t\r\n]+/g, ' ');
const openMs = (s) => Date.parse(String(s.openDate ?? '').replace(' ', 'T') + '+09:00');
const toMs = (str) => Date.parse(String(str).replace(' ', 'T'));   // 'YYYY-MM-DD HH:MM:SS' (이 맥의 시간대)
const safe = (s) => String(s).replace(/[\/\\:*?"<>|\s]+/g, '_');

async function api(url) {
    const r = await fetch(url, { headers: { 'User-Agent': UA } });
    const j = await r.json().catch(() => ({}));
    return { content: j.content ?? null, date: r.headers.get('date') };
}

// 채팅 서버에 읽기 전용으로 잠깐 붙어 최근 채팅 50개와 채팅방 접속 인원만 받고 끊는다.
function recentChat(cid, token, count = 50) {
    return new Promise((resolve) => {
        const n = [...cid].reduce((a, c) => a + c.charCodeAt(0), 0) % 9 + 1;
        const ws = new WebSocket(`wss://kr-ss${n}.chat.naver.com/chat`);
        const done = (v) => { clearTimeout(timer); try { ws.close(); } catch {} resolve(v); };
        const timer = setTimeout(() => done(null), 8000);
        const send = (o) => ws.send(JSON.stringify({ ver: '2', svcid: 'game', cid, ...o }));
        ws.onopen = () => send({ cmd: 100, tid: 1, bdy: { uid: null, devType: 2001, accTkn: token, auth: 'READ' } });
        ws.onmessage = (e) => {
            const m = JSON.parse(e.data);
            if (m.cmd === 10100) send({ cmd: 5101, tid: 2, sid: m.bdy.sid, bdy: { recentMessageCount: count } });
            else if (m.cmd === 15101) done(m.bdy);
        };
        ws.onerror = () => done(null);
    });
}

async function collect(channelId) {
    const [ld, ch, vd] = await Promise.all([
        api(`${API}/service/v3/channels/${channelId}/live-detail`),
        api(`${API}/service/v1/channels/${channelId}`),
        api(`${API}/service/v1/channels/${channelId}/videos?sortType=LATEST&pagingType=PAGE&page=0&size=10`),
    ]);
    const d = ld.content || {};
    const s = {
        checkedAt: Date.now(),
        serverDate: ld.date,
        channelId,
        name: ch.content?.channelName || d.channel?.channelName || channelId.slice(0, 8),
        followers: ch.content?.followerCount ?? null,
        live: d.status === 'OPEN',
        title: d.liveTitle ?? '',
        category: d.liveCategoryValue ?? '',
        openDate: d.openDate ?? '',
        viewers: d.concurrentUserCount ?? 0,
        chatActive: d.chatActive,
        chatGroup: d.chatAvailableGroup ?? '',
        chatCondition: d.chatAvailableCondition ?? '',
        thumbUrl: d.liveImageUrl ? d.liveImageUrl.replace('{type}', '720') : null,
        vodViews: (vd.content?.data || []).map((v) => v.readCount).filter((n) => Number.isFinite(n)),
        chatUsers: null,
        chats: [],
    };
    if (s.live && d.chatChannelId) {
        const tok = await api(`https://comm-api.game.naver.com/nng_main/v1/chats/access-token?channelId=${d.chatChannelId}&chatType=STREAMING`);
        const bdy = tok.content?.accessToken ? await recentChat(d.chatChannelId, tok.content.accessToken) : null;
        if (bdy) {
            // 닉네임·채팅 내용은 저장하지 않는다. 계정은 이번 점검 안에서만 통하는 번호로 바꾼다.
            const ids = new Map();
            const who = (uid) => uid === channelId ? '스트리머' : (ids.has(uid) ? ids.get(uid) : ids.set(uid, `계정${ids.size + 1}`).get(uid));
            s.chatUsers = bdy.userCount ?? null;
            s.chats = (bdy.messageList || [])
                .filter((m) => m.messageTypeCode === 1 || m.messageTypeCode === 10)
                .map((m) => ({ t: m.messageTime, member: m.memberCount ?? null, who: who(m.userId), type: m.messageTypeCode }))
                .sort((a, b) => a.t - b.t);
        }
    }
    return s;
}

// 채팅방 인원이 짧은 시간에 크게 뛴 구간 중 가장 큰 것. 조금씩 늘어난 것은 잡지 않는다.
function findJump(series) {
    let best = null;
    for (let i = 1; i < series.length; i++) {
        const cur = series[i];
        let j = i - 1;
        while (j > 0 && cur.t - series[j - 1].t <= T.jumpWindowMin * 60000) j--;
        const from = series.slice(j, i).reduce((a, b) => (b.member < a.member ? b : a));
        const diff = cur.member - from.member;
        if (diff >= T.jumpAbs && cur.member >= from.member * T.jumpRatio
            && (!best || diff > best.to.member - best.from.member)) best = { from, to: cur };
    }
    return best;
}

function analyze(s, prev) {
    const now = s.checkedAt, V = s.viewers;
    const last = s.chats.at(-1);
    const lastChatMin = last ? Math.round((now - last.t) / 60000) : null;
    const recent = s.chats.filter((c) => now - c.t <= 30 * 60000);
    const chatters30 = new Set(recent.map((c) => c.who)).size;
    const vod = [...s.vodViews].sort((a, b) => a - b);
    const vodMedian = vod.length ? vod[Math.floor(vod.length / 2)] : null;
    const settled = (openMs(s) || 0) + T.startGraceMin * 60000;
    const series = s.chats.filter((c) => c.member != null && c.t >= settled).map((c) => ({ t: c.t, member: c.member }));
    if (s.chatUsers != null) series.push({ t: now, member: s.chatUsers });
    const jump = findJump(series);

    // 채팅 활동량: 최근 채팅(최대 50개)이 걸친 시간으로 나눈 분당 개수, 참여 계정 수, 한 계정 쏠림
    const chatSpanMin = s.chats.length ? Math.max((now - s.chats[0].t) / 60000, 1 / 6) : null;
    const chatRate = s.chats.length >= 2 ? s.chats.length / chatSpanMin : null;
    const perAccount = {};
    for (const c of s.chats) perAccount[c.who] = (perAccount[c.who] || 0) + 1;
    const chatters = Object.keys(perAccount).length;
    const topShare = s.chats.length ? Math.max(...Object.values(perAccount)) / s.chats.length : null;

    const signals = [];
    if (s.chatUsers != null && V >= T.minViewers && s.chatUsers < V * T.chatRoomRatio)
        signals.push(`채팅방 접속 인원(${s.chatUsers}명)이 시청자수(${V}명)의 ${T.chatRoomRatio * 100}% 미만`);
    if (jump) {
        // 채팅이 뜸하면 두 값 사이가 길다. 그 사이 언제 늘었는지는 알 수 없으니 간격을 같이 적는다.
        const gap = Math.round((jump.to.t - jump.from.t) / 60000);
        signals.push(`채팅방 인원 ${gap <= T.jumpWindowMin ? '급증' : '크게 증가'}: ${hm(jump.from.t)} ${jump.from.member}명 → ${hm(jump.to.t)} ${jump.to.member}명`
            + ` (${gap}분 사이${gap > T.jumpWindowMin ? ', 그 사이 채팅이 없어 정확한 시점은 모름' : ''})`);
    }
    if (s.chatUsers != null && s.chatActive !== false && V >= T.minViewers && (lastChatMin === null || lastChatMin > T.silenceMin))
        signals.push(`시청자 ${V}명인데 ${lastChatMin === null ? '채팅 기록이 없음' : `마지막 채팅이 ${lastChatMin}분 전`}`);
    if (prev && V - prev.viewers >= T.jumpAbs && V >= prev.viewers * T.prevRatio)
        signals.push(`직전 점검 대비 급증: ${prev.time.slice(5, 16)} ${prev.viewers}명 → 지금 ${V}명`);
    if (vod.length >= 3 && V >= 10 && V >= vodMedian * T.vodRatio)
        signals.push(`(참고) 시청자수(${V}명)가 다시보기 조회수 중앙값(${vodMedian}회)의 ${T.vodRatio}배 이상`);
    if (s.followers > 0 && V >= T.minViewers && V > s.followers * T.followerRatio)
        signals.push(`(참고) 시청자수(${V}명)가 팔로워(${s.followers}명)의 ${T.followerRatio * 100}%를 넘음`);
    if (s.chats.length >= 20 && V >= T.fewChattersViewers && chatters <= T.fewChatters)
        signals.push(`(참고) 시청자 ${V}명인데 최근 채팅 ${s.chats.length}개가 계정 ${chatters}개에서만 나옴`);
    return { lastChatMin, chats30: recent.length, chatters30, vodMedian, series, jump, chatSpanMin, chatRate, chatters, topShare, signals };
}

function summary(s, a, prev) {
    const L = [];
    L.push(`[치지직 방송 점검] ${s.name} (${s.channelId})`);
    L.push(`점검 시각: ${full(s.checkedAt)} (치지직 서버 응답 시각: ${s.serverDate})`);
    L.push(`방송 주소: https://chzzk.naver.com/live/${s.channelId}`);
    L.push(`제목: ${s.title}`);
    const el = Math.max(0, Math.round((s.checkedAt - openMs(s)) / 60000));
    L.push(`카테고리: ${s.category} / 방송 시작: ${s.openDate} (${Math.floor(el / 60)}시간 ${el % 60}분 경과)`);
    L.push(`팔로워: ${s.followers ?? '?'}명 / 시청자수: ${s.viewers}명`);
    if (s.chatUsers == null) L.push('채팅 정보: 받지 못함 (연령 제한 방송이거나 채팅 서버 응답 없음)');
    else {
        L.push(`채팅방 접속 인원: ${s.chatUsers}명 (시청자수의 ${s.viewers ? (s.chatUsers / s.viewers).toFixed(1) : '?'}배)`);
        L.push(`채팅 권한: ${s.chatGroup || '?'} / ${s.chatCondition || '?'}`);
        if (s.chats.length) {
            L.push(`최근 채팅 ${s.chats.length}개: ${full(s.chats[0].t)} ~ ${full(s.chats.at(-1).t)}, 마지막 채팅 ${a.lastChatMin}분 전`);
            L.push(`최근 30분: 채팅 ${a.chats30}개, 채팅한 계정 ${a.chatters30}개 (채팅 봇 포함 가능)`);
            if (a.chatRate != null) L.push(`채팅 활동량: 분당 ${a.chatRate.toFixed(a.chatRate < 10 ? 1 : 0)}개 (최근 ${s.chats.length}개가 ${Math.round(a.chatSpanMin)}분에 걸침), `
                + `참여 계정 ${a.chatters}개, 가장 많이 친 계정 비중 ${Math.round(a.topShare * 100)}%`);
            const shown = a.series.filter((p, i, arr) => i === 0 || i === arr.length - 1 || Math.abs(p.member - arr[i - 1].member) >= 3);
            L.push(`채팅방 인원 변화(채팅에 찍힌 값): ${shown.map((p) => `${hm(p.t)} ${p.member}`).join(' → ')}`);
        } else L.push('최근 채팅: 없음');
    }
    if (s.vodViews.length) L.push(`다시보기 조회수(최근 ${s.vodViews.length}개): ${s.vodViews.join(', ')} / 중앙값 ${a.vodMedian}`);
    if (prev) L.push(`같은 방송의 직전 점검: ${prev.time} 시청자 ${prev.viewers}명, 채팅방 ${prev.chatUsers}명`);
    L.push('');
    L.push(a.signals.length ? `의심 신호 ${a.signals.length}건:` : '의심 신호 없음');
    for (const x of a.signals) L.push(`  - ${x}`);
    L.push('');
    L.push('치지직 공개 정보만으로 본 결과입니다. 신호는 판정 기준을 넘었다는 뜻일 뿐 조작을 확정하지 않습니다.');
    L.push('실제 접속 기록은 치지직만 확인할 수 있으니, 신고할 때 참고 자료로 붙이세요.');
    return L.join('\n');
}

const HEADER = '점검시각\t채널ID\t채널명\t방송시작\t시청자\t채팅방인원\t팔로워\t마지막채팅_분전\t30분_채팅계정\t다시보기_중앙값\t신호수\t제목\t채팅속도_분당\t채팅참여계정\n';

function historyRows() {
    if (!fs.existsSync(HISTORY)) return [];
    return fs.readFileSync(HISTORY, 'utf8').trim().split('\n').slice(1).map((l) => l.split('\t'));
}

function loadPrev(channelId, openDate) {
    const r = historyRows().findLast((c) => c[1] === channelId && c[3] === openDate);
    return r ? { time: r[0], viewers: Number(r[4]), chatUsers: r[5] } : null;
}

// 이 채널을 점검했던 기록 전부(최근 200회). 앱이 추세 그래프로 그린다.
function loadHistory(channelId) {
    const num = (v) => (v === undefined || v === '' ? null : Number(v));
    return historyRows().filter((c) => c[1] === channelId).slice(-200).map((c) => ({
        time: c[0], openDate: c[3], viewers: Number(c[4]), chatUsers: num(c[5]), followers: num(c[6]),
        signals: Number(c[10]) || 0, chatRate: num(c[12]),
    }));
}

function appendHistory(s, a) {
    if (!fs.existsSync(HISTORY)) fs.writeFileSync(HISTORY, HEADER);
    else {
        // 예전 형식(채팅 활동량 열이 없는 머리줄)이면 머리줄만 새것으로 바꾼다
        const txt = fs.readFileSync(HISTORY, 'utf8'), nl = txt.indexOf('\n');
        if (!txt.slice(0, nl).includes('채팅속도_분당')) fs.writeFileSync(HISTORY, HEADER + txt.slice(nl + 1));
    }
    fs.appendFileSync(HISTORY, [full(s.checkedAt), s.channelId, clean(s.name), s.openDate, s.viewers, s.chatUsers ?? '',
        s.followers ?? '', a.lastChatMin ?? '', a.chatters30, a.vodMedian ?? '', a.signals.length, clean(s.title),
        a.chatRate == null ? '' : a.chatRate.toFixed(2), a.chatters].join('\t') + '\n');
}

// ---- 지켜보기 기록: 지켜보기/<채널>_<ID 앞 8자>/<방송시작>.tsv ----

function loadWatch(channelId) {      // 방송시작 → [{t, viewers, chatUsers}]
    const out = {};
    if (!fs.existsSync(WATCH_DIR)) return out;
    for (const d of fs.readdirSync(WATCH_DIR).filter((x) => x.endsWith('_' + channelId.slice(0, 8)))) {
        for (const f of fs.readdirSync(path.join(WATCH_DIR, d))) {
            const m = f.match(/^(\d{4}-\d\d-\d\d)-(\d\d)-(\d\d)-(\d\d)\.tsv$/);
            if (!m) continue;
            const rows = fs.readFileSync(path.join(WATCH_DIR, d, f), 'utf8').trim().split('\n').slice(1).map((l) => l.split('\t'))
                .map((c) => ({ t: toMs(c[0]), viewers: Number(c[1]), chatUsers: c[2] === '' ? null : Number(c[2]) }))
                .filter((r) => Number.isFinite(r.t));
            (out[`${m[1]} ${m[2]}:${m[3]}:${m[4]}`] ||= []).push(...rows);
        }
    }
    return out;
}

// 방송 도중 가장 크게 늘어난 구간: 그때까지의 최저점 → 그 뒤의 최고점. 시작 직후는 뺀다.
function riseOf(pts) {
    let low = null, best = null;
    for (const p of pts) {
        if (p.min < T.startGraceMin) continue;
        if (!low || p.viewers < low.viewers) low = p;
        if (!best || p.viewers - low.viewers > best.high.viewers - best.low.viewers) best = { low, high: p };
    }
    const rose = !!best && best.high.viewers - best.low.viewers >= T.jumpAbs && best.high.viewers >= best.low.viewers * T.prevRatio;
    return { low: best?.low ?? null, high: best?.high ?? null, rose };
}

// 점검기록과 지켜보기 기록을 방송별로 묶어, 같은 모양이 되풀이되는지 본다.
function buildPattern(channelId, name) {
    const by = {};
    for (const c of historyRows()) {
        if (c[1] === channelId) (by[c[3]] ||= []).push({ t: toMs(c[0]), viewers: Number(c[4]), chatUsers: c[5] === '' ? null : Number(c[5]) });
    }
    for (const [open, rows] of Object.entries(loadWatch(channelId))) (by[open] ||= []).push(...rows);
    const broadcasts = Object.keys(by).sort().map((openDate) => {
        const open = openMs({ openDate });
        let pts = by[openDate].sort((a, b) => a.t - b.t).map((p) => ({ ...p, min: (p.t - open) / 60000 }));
        const { low, high, rose } = riseOf(pts);
        const count = pts.length;
        // ponytail: 그래프용으로만 400점까지 솎는다(봉우리가 빠질 수 있음). 판정은 위에서 전체로 이미 했다.
        if (pts.length > 400) pts = Array.from({ length: 400 }, (_, i) => pts[Math.floor(i * pts.length / 400)]);
        const pick = (p) => p && { time: hm(p.t), viewers: p.viewers };
        return { openDate, count, rose, low: pick(low), high: pick(high),
            points: pts.map(({ min, viewers, chatUsers }) => ({ min: Math.round(min * 10) / 10, viewers, chatUsers })) };
    });
    const roseCount = broadcasts.filter((b) => b.rose).length;
    const L = [`[반복 패턴 요약] ${name} (${channelId})`,
        `방송 주소: https://chzzk.naver.com/live/${channelId}`,
        `기록된 방송 ${broadcasts.length}편 중 ${roseCount}편에서, 방송 도중 시청자수가 ${T.jumpAbs}명 이상이면서 ${T.prevRatio}배 이상 늘었습니다.`,
        `(방송 시작 ${T.startGraceMin}분 이내는 제외. 기록이 없는 시간대의 값은 모릅니다.)`, ''];
    for (const b of broadcasts) {
        L.push(`- ${b.openDate} 시작 방송: 기록 ${b.count}회` + (b.low ? `, 최저 ${b.low.viewers}명(${b.low.time}) → 이후 최고 ${b.high.viewers}명(${b.high.time})` : '')
            + (b.rose ? ' [크게 늘어남]' : ''));
    }
    L.push('', '치지직 공개 정보를 직접 기록한 것입니다. 조작을 확정하지 않으며, 비정상 유입인지 확인을 요청하는 참고 자료입니다.');
    return { broadcasts, roseCount, text: L.join('\n') };
}

// 지켜보기에서 한 번 재는 값. 점검(collect)보다 가볍다: 방송 정보 1번 + 채팅방 인원 1번.
async function sample(channelId) {
    const { content: d } = await api(`${API}/service/v3/channels/${channelId}/live-detail`);
    if (!d || d.status !== 'OPEN') return null;
    let chatUsers = null;
    if (d.chatChannelId) {
        const tok = await api(`https://comm-api.game.naver.com/nng_main/v1/chats/access-token?channelId=${d.chatChannelId}&chatType=STREAMING`);
        const bdy = tok.content?.accessToken ? await recentChat(d.chatChannelId, tok.content.accessToken, 1) : null;
        chatUsers = bdy?.userCount ?? null;
    }
    return { t: Date.now(), name: d.channel?.channelName || channelId.slice(0, 8), openDate: d.openDate ?? '',
        viewers: d.concurrentUserCount ?? 0, chatUsers, category: d.liveCategoryValue ?? '', title: d.liveTitle ?? '' };
}

// 멈출 때까지(또는 방송이 끝나거나 12시간이 지날 때까지) 일정 간격으로 잰다.
// 앱이 띄운 경우 앱이 사라지면 같이 끝난다: 부모가 없어지거나 출력이 막히면 종료.
async function watch(channelId, intervalSec) {
    process.stdout.on('error', () => process.exit(0));
    const end = Date.now() + 12 * 3600e3;
    let rows = null, file = null;
    while (Date.now() < end && process.ppid !== 1) {
        const r = await sample(channelId).catch(() => undefined);
        if (r === null) { say('방송이 끝났습니다.'); emit({ type: 'watchEnd', message: '방송이 끝나서 지켜보기를 멈췄습니다' }); return; }
        if (r) {
            if (!rows) {      // 같은 방송을 전에 지켜본 기록이 있으면 이어서 쌓는다
                const dir = path.join(WATCH_DIR, `${safe(r.name)}_${channelId.slice(0, 8)}`);
                fs.mkdirSync(dir, { recursive: true });
                file = path.join(dir, r.openDate.replace(/[: ]/g, '-') + '.tsv');
                if (!fs.existsSync(file)) fs.writeFileSync(file, '시각\t시청자\t채팅방인원\t카테고리\t제목\n');
                rows = (loadWatch(channelId)[r.openDate] || []).map((x) => ({ ...x, title: '' }));
            }
            fs.appendFileSync(file, [full(r.t), r.viewers, r.chatUsers ?? '', clean(r.category), clean(r.title)].join('\t') + '\n');
            const first = rows.length === 0 || !rows.sent;
            rows.push({ t: r.t, viewers: r.viewers, chatUsers: r.chatUsers, title: r.title });
            const settled = (openMs(r) || 0) + T.startGraceMin * 60000;
            const jump = findJump(rows.filter((x) => x.t >= settled).map((x) => ({ t: x.t, member: x.viewers })));
            const last30 = rows.filter((x) => r.t - x.t <= 30 * 60000).map((x) => x.viewers);
            say(`${hm(r.t)}  시청자 ${r.viewers} / 채팅방 ${r.chatUsers ?? '?'}  ${r.title.slice(0, 30)}`);
            emit({ type: 'tick', channelId, name: r.name, openDate: r.openDate, file, jump,
                range30: [Math.min(...last30), Math.max(...last30)], title: r.title,
                rows: first ? rows.map(({ t, viewers, chatUsers }) => ({ t, viewers, chatUsers })) : undefined,
                row: { t: r.t, viewers: r.viewers, chatUsers: r.chatUsers } });
            rows.sent = true;
        }
        await sleep(intervalSec * 1000);
    }
}

async function saveEvidence(s, a, text) {
    const stamp = full(s.checkedAt).replace(/[-:]/g, '').replace(' ', '-');
    const dir = path.join(BASE, '증거', `${safe(s.name)}_${s.channelId.slice(0, 8)}`, stamp);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, '요약.txt'), text + '\n');
    fs.writeFileSync(path.join(dir, '원본.json'), JSON.stringify({ ...s, 분석: { ...a, series: undefined } }, null, 4));
    if (s.thumbUrl) {
        const r = await fetch(s.thumbUrl, { headers: { 'User-Agent': UA } }).catch(() => null);
        if (r?.ok) fs.writeFileSync(path.join(dir, '화면.jpg'), Buffer.from(await r.arrayBuffer()));
    }
    return dir;
}

// 한 채널 점검. saveMin: 신호가 이 개수 이상일 때만 증거 폴더를 만든다.
async function checkOne(channelId, saveMin) {
    const s = await collect(channelId);
    if (!s.live) { emit({ type: 'offline', name: s.name, channelId }); return { s, a: null }; }
    const prev = loadPrev(channelId, s.openDate);
    const a = analyze(s, prev);
    const text = summary(s, a, prev);
    const dir = a.signals.length >= saveMin ? await saveEvidence(s, a, text) : null;
    appendHistory(s, a);
    emit({ type: 'result', s, a, prev, dir, text, history: loadHistory(channelId), pattern: buildPattern(channelId, s.name),
        channelDir: path.join(BASE, '증거', `${safe(s.name)}_${channelId.slice(0, 8)}`) });
    return { s, a, text, dir };
}

async function scan(o) {
    const targets = [];
    let cursor = { concurrentUserCount: o.max + 1, liveId: 99999999999 };
    while (cursor && targets.length < o.limit) {
        const { content } = await api(`${API}/service/v1/lives?size=50&sortType=POPULAR&concurrentUserCount=${cursor.concurrentUserCount}&liveId=${cursor.liveId}`);
        const data = content?.data || [];
        if (!data.length || data[0].concurrentUserCount < o.min) break;
        for (const x of data) {
            if (x.concurrentUserCount > o.max || x.concurrentUserCount < o.min) continue;
            if (o.category && !(x.liveCategoryValue || '').includes(o.category)) continue;
            if (targets.length < o.limit) targets.push(x.channel.channelId);
        }
        cursor = content.page?.next;
    }
    say(`시청자 ${o.min}~${o.max}명 방송 ${targets.length}곳 점검${o.category ? ` (카테고리: ${o.category})` : ''}`);
    emit({ type: 'start', total: targets.length });
    const flagged = [];
    for (const id of targets) {
        try {
            const r = await checkOne(id, 2);
            if (!r.a) continue;
            say(`  ${r.a.signals.length ? '!' : ' '} ${r.s.name}  시청자 ${r.s.viewers} / 채팅방 ${r.s.chatUsers ?? '?'} / 마지막 채팅 ${r.a.lastChatMin ?? '?'}분 전`);
            if (r.a.signals.length) flagged.push(r);
        } catch (e) {
            say(`    ${id.slice(0, 8)} 실패: ${e.message}`);
            emit({ type: 'error', channelId: id, message: e.message });
        }
        await sleep(300);
    }
    flagged.sort((x, y) => y.a.signals.length - x.a.signals.length);
    say(`\n의심 신호가 있는 방송 ${flagged.length}곳`);
    for (const r of flagged) {
        say(`\n${r.s.name}  https://chzzk.naver.com/live/${r.s.channelId}`);
        for (const x of r.a.signals) say(`  - ${x}`);
        if (r.dir) say(`  증거 저장: ${r.dir}`);
    }
    say(`\n자세히 보고 증거를 남기려면: node check.mjs <채널ID>`);
}

// 예시 데이터. 실제 채널이 아니다. 네트워크를 쓰지 않고 아무것도 저장하지 않는다.
function demo() {
    const now = Date.now(), M = 60000;
    const id = (n) => n.toString(16).padStart(32, '0');
    const make = (n, o) => {
        const s = { checkedAt: now, serverDate: new Date(now).toUTCString(), channelId: id(n), live: true, chatActive: true,
            chatGroup: 'ALL', chatCondition: 'NONE', thumbUrl: null, openDate: full(now - o.openMin * M), ...o.s,
            chats: o.chats.map(([ago, member, who]) => ({ t: now - ago * M, member, who, type: 1 })) };
        const a = analyze(s, null);
        const broadcasts = o.days.map((d, i) => {
            const pts = d.map(([min, viewers, chatUsers]) => ({ min, viewers, chatUsers, t: now - (o.days.length - 1 - i) * 1440 * M - (o.openMin - min) * M }));
            const { low, high, rose } = riseOf(pts);
            const pick = (p) => p && { time: hm(p.t), viewers: p.viewers };
            return { openDate: full(now - (o.days.length - 1 - i) * 1440 * M - o.openMin * M), count: pts.length, rose, low: pick(low), high: pick(high),
                points: pts.map(({ min, viewers, chatUsers }) => ({ min, viewers, chatUsers })) };
        });
        const pattern = { broadcasts, roseCount: broadcasts.filter((b) => b.rose).length, text: '(예시 데이터)' };
        const history = [{ time: full(now), openDate: s.openDate, viewers: s.viewers, chatUsers: s.chatUsers, followers: s.followers, signals: a.signals.length, chatRate: a.chatRate }];
        emit({ type: 'result', s, a, prev: null, dir: null, text: summary(s, a, null), history, pattern, channelDir: null });
        say(summary(s, a, null) + '\n');
    };
    // 방송 한 편: 조용하다가 3시간 반쯤 지나 갑자기 늘어나는 모양
    const jumpy = (k) => [[20, 9, 16], [60, 8 + k, 15], [100, 7, 14], [140, 8, 15], [180, 7 + k, 14], [205, 8, 15], [215, 88 + k, 38], [235, 95, 40], [260, 96 - k, 41]];
    const steady = (v, c) => [[20, v - 6, c - 8], [70, v - 2, c - 3], [130, v + 3, c + 4], [190, v + 1, c], [250, v, c]];
    emit({ type: 'start', total: 4 });
    make(0xa1, { openMin: 260, days: [jumpy(0), jumpy(2), jumpy(1)],
        s: { name: '예시 채널 A', title: '[예시] 자리를 비운 뒤 시청자수가 갑자기 늘어난 방송', category: '예시 게임', followers: 520, viewers: 96, chatUsers: 41, vodViews: [7, 5, 9, 12, 6, 7, 4] },
        chats: [[200, 15, '스트리머'], [198, 15, '계정1'], [190, 14, '계정2'], [176, 15, '계정1'], [175, 15, '계정3'], [160, 14, '계정1'], [151, 14, '계정2'], [150, 15, '스트리머'], [139, 14, '계정1'],
            [128, 15, '계정2'], [127, 15, '계정1'], [115, 14, '계정3'], [101, 15, '계정1'], [100, 15, '계정2'], [92, 14, '계정1'], [84, 15, '계정1'], [75, 15, '계정2'], [70, 15, '계정1'],
            [66, 38, '계정2'], [64, 41, '계정1'], [60, 40, '계정1'], [57, 41, '계정2'], [52, 40, '계정1']] });
    make(0xb2, { openMin: 185, days: [steady(80, 126), steady(88, 135)],
        s: { name: '예시 채널 B', title: '[예시] 채팅이 활발한 보통 방송', category: '예시 토크', followers: 21400, viewers: 85, chatUsers: 132, vodViews: [310, 280, 455, 390, 262] },
        chats: [...Array(50)].map((_, i) => [4.2 - i * 0.084, 130 + (i % 5), `계정${(i * 8) % 21 + 1}`]) });
    make(0xc3, { openMin: 95, days: [steady(24, 39)],
        s: { name: '예시 채널 C', title: '[예시] 작은 방송', category: '예시 게임', followers: 1830, viewers: 23, chatUsers: 38, vodViews: [41, 35, 52, 38] },
        chats: [...Array(40)].map((_, i) => [58 - i * 1.45, 36 + (i % 4), `계정${(i * 4) % 9 + 1}`]) });
    make(0xd4, { openMin: 140, days: [steady(52, 70)],
        s: { name: '예시 채널 D', title: '[예시] 다시보기 조회수보다 실시간 시청자가 많은 방송', category: '예시 음악', followers: 2900, viewers: 54, chatUsers: 71, vodViews: [12, 18, 9, 15, 11] },
        chats: [...Array(45)].map((_, i) => [40 - i * 0.85, 68 + (i % 6), `계정${(i * 5) % 14 + 1}`]) });
}

function selftest() {
    const now = Date.UTC(2026, 10, 20, 2, 0), min = 60000;
    const base = { checkedAt: now, viewers: 30, followers: 5000, chatActive: true, vodViews: [], chatUsers: 45, chats: [] };
    const chat = (agoMin, member, who = '계정1') => ({ t: now - agoMin * min, member, who, type: 1 });

    // 평온한 방송: 신호 없음
    let a = analyze({ ...base, chats: [chat(20, 44), chat(5, 45), chat(1, 45)] }, null);
    assert.deepEqual(a.signals, []);
    // 채팅방 인원 급증 (27 → 45), 천천히 늘어난 것은 잡지 않음
    a = analyze({ ...base, chats: [chat(120, 27), chat(90, 27), chat(25, 45), chat(2, 44)] }, null);
    assert.equal(a.signals.length, 1); assert.match(a.signals[0], /크게 증가.*65분 사이/); assert.equal(a.jump.from.member, 27);
    a = analyze({ ...base, chats: [chat(100, 27), chat(80, 32), chat(60, 37), chat(40, 41), chat(20, 45), chat(1, 45)] }, null);
    assert.deepEqual(a.signals, []);
    // 방송 시작 직후에 몰려든 것은 급증으로 보지 않음
    a = analyze({ ...base, openDate: '2026-11-20 10:30:00', chats: [chat(28, 5), chat(20, 45), chat(1, 45)] }, null);
    assert.deepEqual(a.signals, []);
    // 시청자만 많고 채팅방은 비어 있음 + 채팅 끊김
    a = analyze({ ...base, viewers: 100, chatUsers: 20, chats: [chat(50, 20)] }, null);
    assert.equal(a.signals.length, 2);
    // 직전 점검 대비 급증
    a = analyze({ ...base, chats: [chat(1, 45)] }, { time: '2026-11-20 01:00:00', viewers: 7, chatUsers: '27' });
    assert.match(a.signals[0], /직전 점검/);
    // 채팅 활동량: 10분 동안 20개 = 분당 2개, 계정 2개, 한 계정이 75%
    a = analyze({ ...base, viewers: 80, chatUsers: 120, chats: [...Array(15)].map((_, i) => chat(10 - i * 0.5, 120, '계정1')).concat([...Array(5)].map((_, i) => chat(2 - i * 0.3, 120, '계정2'))) }, null);
    assert.equal(Math.round(a.chatRate), 2); assert.equal(a.chatters, 2); assert.equal(a.topShare, 0.75);
    assert.equal(a.signals.length, 1); assert.match(a.signals[0], /계정 2개에서만/);
    // 반복 패턴: 방송 도중 16명 → 40명은 '크게 늘어남', 시작 직후 몰려든 것과 조금 늘어난 것은 아님
    let rz = riseOf([{ min: 5, viewers: 3 }, { min: 60, viewers: 18 }, { min: 120, viewers: 16 }, { min: 200, viewers: 40 }, { min: 260, viewers: 38 }]);
    assert.equal(rz.rose, true); assert.equal(rz.low.viewers, 16); assert.equal(rz.high.viewers, 40);
    rz = riseOf([{ min: 2, viewers: 3 }, { min: 10, viewers: 60 }, { min: 30, viewers: 62 }, { min: 90, viewers: 66 }]);
    assert.equal(rz.rose, false);
    // 작은 방송은 비율 신호를 내지 않음
    a = analyze({ ...base, viewers: 8, chatUsers: 2, chats: [] }, null);
    assert.deepEqual(a.signals, []);
    console.log('selftest ok');
}

const channelArg = (v) => String(v ?? '').match(/[0-9a-f]{32}/)?.[0];
if (args[0] === 'selftest') selftest();
else if (args[0] === 'demo') demo();
else if (args[0] === 'watch' || args[0] === 'pattern') {
    const id = channelArg(args[1]);
    if (!id) { console.error(`채널 ID를 찾지 못함: ${args[1]}`); emit({ type: 'error', message: '채널 ID를 찾지 못함' }); process.exit(1); }
    if (args[0] === 'watch') await watch(id, Math.max(10, Number(args[args.indexOf('--interval') + 1]) || 30));
    else { const pt = buildPattern(id, id.slice(0, 8)); say(pt.text); emit({ type: 'pattern', pattern: pt }); }
}
else if (args[0] === 'scan') {
    const o = { min: 10, max: 100, limit: 30, category: '' };
    for (let i = 1; i < args.length; i += 2) {
        const k = args[i].replace(/^--/, '');
        if (!(k in o) || args[i + 1] === undefined) { console.error(`알 수 없는 옵션: ${args[i]}`); process.exit(1); }
        o[k] = k === 'category' ? args[i + 1] : Number(args[i + 1]);
    }
    await scan(o);
} else if (args.length) {
    for (const arg of args) {
        const id = arg.match(/[0-9a-f]{32}/)?.[0];
        if (!id) { console.error(`채널 ID를 찾지 못함: ${arg}`); emit({ type: 'error', channelId: arg, message: '채널 ID를 찾지 못함' }); continue; }
        const r = await checkOne(id, 0);
        if (!r.a) { say(`${r.s.name}: 지금 방송 중이 아닙니다.`); continue; }
        say(r.text);
        say(`\n증거 저장: ${r.dir}`);
    }
} else {
    console.log(fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').slice(1, 11).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
}
