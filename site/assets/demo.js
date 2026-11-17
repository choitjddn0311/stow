// 직접 해 보는 데모. 영상 정보는 브라우저가 유튜브 oEmbed에서 직접 가져오고, 추출은 흉내만 낸다.
// 주소 규칙과 오류 문구는 앱(YouTubeURL.swift, EngineError.swift)과 맞춘다.
(function () {
  "use strict";
  const root = document.getElementById("demo");
  if (!root) return;

  const ko = (document.documentElement.lang || "").startsWith("ko");
  const T = ko ? {
    invalid: "유튜브 영상 주소가 아닙니다. 주소를 확인해 주세요.",
    channel: "채널 주소는 지원하지 않습니다. 영상이나 재생목록 주소를 입력해 주세요.",
    unsupported: "지원하지 않는 주소입니다. 유튜브 영상 주소를 입력해 주세요.",
    unavailable: "영상 정보를 불러오지 못했습니다. 비공개·삭제된 영상이거나 외부 표시가 막힌 영상일 수 있습니다.",
    network: "영상 정보를 불러오지 못했습니다. 인터넷 연결을 확인해 주세요.",
    video: "영상", playlist: "재생목록",
    extractAs: { MP3: "MP3로 추출", WAV: "WAV로 추출", FLAC: "FLAC으로 추출" },
    downloading: p => `다운로드 중 ${p}%`, converting: "변환 중…",
    saved: "저장했습니다 (예시)", folder: "폴더에 재생목록 영상을 저장합니다",
  } : {
    invalid: "That's not a YouTube video link. Please check the address.",
    channel: "Channel pages aren't supported. Enter a video or playlist link.",
    unsupported: "This link isn't supported. Enter a YouTube video link.",
    unavailable: "Couldn't load the video info. It may be private, deleted, or blocked from being shown on other sites.",
    network: "Couldn't load the video info. Check your internet connection.",
    video: "Video", playlist: "Playlist",
    extractAs: { MP3: "Extract as MP3", WAV: "Extract as WAV", FLAC: "Extract as FLAC" },
    downloading: p => `Downloading ${p}%`, converting: "Converting…",
    saved: "Saved (demo)", folder: "Playlist videos go into this folder",
  };

  const $ = sel => root.querySelector(sel);
  const input = $("#demo-url"), form = $("#demo-form"), msg = $("#demo-msg"), meta = $("#demo-meta"),
    opts = $("#demo-opts"), go = $("#demo-go"), quality = $("#demo-quality"), job = $("#demo-job"),
    fill = $("#demo-fill"), jobText = $("#demo-jobtext"), pct = $("#demo-pct"), done = $("#demo-done"),
    file = $("#demo-file"), again = $("#demo-again"), example = $("#demo-example");
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  let format = "MP3", current = null, run = 0;

  // 앱과 같은 규칙: youtube.com·youtu.be(하위 도메인 포함)만, 채널 페이지는 따로 안내.
  function parse(text) {
    let s = text.trim();
    if (!s) return null;
    if (!/^[a-z]+:\/\//i.test(s)) s = "https://" + s;
    let u;
    try { u = new URL(s); } catch (e) { return { error: T.invalid }; }
    const host = u.hostname.toLowerCase();
    const isYT = ["youtube.com", "youtu.be"].some(h => host === h || host.endsWith("." + h));
    if (!isYT || !/^https?:$/.test(u.protocol)) return { error: T.invalid };
    const path = u.pathname;
    if (path.length <= 1) return { error: T.invalid };
    if (host.endsWith("youtu.be")) {
      const id = path.slice(1).split("/")[0];
      return /^[\w-]{11}$/.test(id) ? { video: id } : { error: T.unsupported };
    }
    const lower = path.toLowerCase();
    if (["/@", "/channel/", "/c/", "/user/", "/feed/"].some(p => lower.startsWith(p))) return { error: T.channel };
    const v = u.searchParams.get("v");
    if (path === "/watch" && v && /^[\w-]{11}$/.test(v)) return { video: v };
    const m = path.match(/^\/(shorts|live|embed)\/([\w-]{11})/);
    if (m) return { video: m[2] };
    const list = u.searchParams.get("list");
    if (list && /^[\w-]+$/.test(list)) return { playlist: list };
    return { error: T.unsupported };
  }

  function show(el, on) { el.hidden = !on; }
  function reset() {
    run++;
    show(msg, false); show(meta, false); show(opts, false); show(job, false); show(done, false);
  }

  async function load() {
    reset();
    const target = parse(input.value);
    if (!target) return;
    if (target.error) { msg.textContent = target.error; show(msg, true); return; }
    const my = run;
    const pageURL = target.video
      ? `https://www.youtube.com/watch?v=${target.video}`
      : `https://www.youtube.com/playlist?list=${target.playlist}`;
    meta.className = "meta skeleton";
    meta.innerHTML = '<div class="thumb"></div><div class="text"><div class="bar" style="width:40%"></div><div class="bar" style="width:85%"></div><div class="bar" style="width:55%"></div></div>';
    show(meta, true);
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 10000);
    let data;
    try {
      const res = await fetch(`https://www.youtube.com/oembed?format=json&url=${encodeURIComponent(pageURL)}`, { signal: ctrl.signal });
      if (!res.ok) throw new Error("status");
      data = await res.json();
    } catch (e) {
      if (my !== run) return;
      show(meta, false);
      msg.textContent = e.message === "status" ? T.unavailable : T.network;
      show(msg, true);
      return;
    } finally { clearTimeout(timer); }
    if (my !== run) return;
    current = { title: String(data.title || ""), author: String(data.author_name || ""), playlist: !!target.playlist };
    meta.className = "meta";
    meta.textContent = "";
    const img = document.createElement("img");
    img.className = "thumb"; img.alt = ""; img.referrerPolicy = "no-referrer";
    img.src = target.video ? `https://i.ytimg.com/vi/${target.video}/hqdefault.jpg` : String(data.thumbnail_url || "");
    const text = document.createElement("div"); text.className = "text";
    const kind = document.createElement("div"); kind.className = "kind"; kind.textContent = current.playlist ? T.playlist : T.video;
    const title = document.createElement("div"); title.className = "title"; title.textContent = current.title;
    const author = document.createElement("div"); author.className = "author"; author.textContent = current.author;
    text.append(kind, title, author);
    meta.append(img, text);
    show(opts, true);
    go.disabled = false;
  }

  // 앱의 파일 이름 규칙(YtDlpClient.sanitize): 경로 문자 치환, 제어 문자는 공백, 공백 정리,
  // 200바이트(UTF-8)까지 글자 단위로 자르기, 앞의 점·공백과 끝 공백 제거, 비면 "오디오".
  const encoder = new TextEncoder();
  const segmenter = typeof Intl.Segmenter === "function" ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null;
  function fileName(title) {
    let name = title.replace(/[\/:]/g, "-").replace(/\p{Cc}/gu, " ").split(/\s+/).filter(Boolean).join(" ");
    if (encoder.encode(name).length > 200) {
      const chars = segmenter ? Array.from(segmenter.segment(name), s => s.segment) : Array.from(name);
      while (chars.length && encoder.encode(chars.join("")).length > 200) chars.pop();
      name = chars.join("");
    }
    name = name.replace(/^[. ]+/, "").replace(/ +$/, "");
    return name || "오디오";
  }

  function setFormat(f) {
    format = f;
    root.querySelectorAll("[data-format]").forEach(b => b.setAttribute("aria-pressed", String(b.dataset.format === f)));
    quality.hidden = f !== "MP3";
    go.textContent = T.extractAs[f];
  }

  function extract() {
    if (!current) return;
    const my = ++run;
    go.disabled = true;
    show(done, false); show(job, true);
    const ext = format.toLowerCase();
    const finish = () => {
      if (my !== run) return;
      show(job, false);
      $("#demo-done .ok").textContent = T.saved;
      const name = fileName(current.title);
      file.textContent = current.playlist ? `${name}/  — ${T.folder}` : `${name}.${ext}`;
      show(done, true);
      go.disabled = false;
    };
    if (reduce) { finish(); return; }
    let p = 0;
    fill.style.width = "0%";
    const step = () => {
      if (my !== run) return;
      p = Math.min(100, p + 4 + Math.round(Math.random() * 6));
      fill.style.width = p + "%"; jobText.textContent = T.downloading(p); pct.textContent = p + "%";
      if (p < 100) setTimeout(step, 90);
      else { jobText.textContent = T.converting; pct.textContent = ""; setTimeout(finish, 700); }
    };
    jobText.textContent = T.downloading(0); pct.textContent = "0%";
    setTimeout(step, 150);
  }

  form.addEventListener("submit", e => { e.preventDefault(); load(); });
  input.addEventListener("paste", () => setTimeout(load, 0));
  root.querySelectorAll("[data-format]").forEach(b => b.addEventListener("click", () => setFormat(b.dataset.format)));
  go.addEventListener("click", extract);
  again.addEventListener("click", () => { reset(); input.value = ""; input.focus(); });
  example.addEventListener("click", () => { input.value = example.dataset.url; load(); });
  setFormat("MP3");
})();
