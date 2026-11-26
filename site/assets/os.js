// Windows에서 열면 Windows 다운로드 버튼을 앞으로 옮기고 주 버튼 모양으로 바꾸며, 단축키를 Windows 것으로 보인다(그 밖은 Mac이 먼저).
(function () {
  "use strict";
  const platform = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || navigator.userAgent;
  if (!/win/i.test(platform)) return;
  // 단축키 표시도 Windows 것으로(예: ⌥⌘Y → Ctrl+Alt+Y)
  document.querySelectorAll("kbd[data-win]").forEach(key => { key.textContent = key.dataset.win; });
  document.querySelectorAll("[data-downloads]").forEach(group => {
    const mac = group.querySelector('[data-os="mac"]');
    const win = group.querySelector('[data-os="win"]');
    if (!mac || !win) return;
    group.insertBefore(win, mac);
    win.classList.remove("alt");
    mac.classList.add("alt");
  });
})();
