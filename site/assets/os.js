// Windows에서 열면 Windows 다운로드 버튼을 앞으로 옮기고 주 버튼 모양으로 바꾼다(그 밖은 Mac이 먼저).
(function () {
  "use strict";
  const platform = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || navigator.userAgent;
  if (!/win/i.test(platform)) return;
  document.querySelectorAll("[data-downloads]").forEach(group => {
    const mac = group.querySelector('[data-os="mac"]');
    const win = group.querySelector('[data-os="win"]');
    if (!mac || !win) return;
    group.insertBefore(win, mac);
    win.classList.remove("alt");
    mac.classList.add("alt");
  });
})();
