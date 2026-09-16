const HOST_NAME = "dev.vpnbypass.manager";
const button = document.querySelector("#toggle");

let target = null;
let bypassed = false;

function storageKey(hostname) {
  return `bypass:${hostname}`;
}

function setReadyLabel() {
  button.textContent = bypassed
    ? "Включить VPN для этого сайта"
    : "Отключить VPN для этого сайта";
  button.disabled = false;
  button.dataset.error = "false";
}

function showError(message) {
  button.textContent = message;
  button.disabled = false;
  button.dataset.error = "true";
}

function normalizeHostname(rawHostname) {
  const hostname = rawHostname.toLowerCase().replace(/\.$/, "");
  if (
    !hostname ||
    hostname.length > 253 ||
    !hostname.includes(".") ||
    !/^[a-z0-9.-]+$/.test(hostname) ||
    hostname.split(".").some((label) =>
      !label ||
      label.length > 63 ||
      label.startsWith("-") ||
      label.endsWith("-")
    )
  ) {
    return null;
  }
  return hostname;
}

async function initialize() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.url) {
    showError("Не удалось определить сайт");
    return;
  }

  let url;
  try {
    url = new URL(tab.url);
  } catch {
    showError("Откройте обычный сайт");
    return;
  }

  if (url.protocol !== "http:" && url.protocol !== "https:") {
    showError("Откройте обычный сайт");
    return;
  }

  target = normalizeHostname(url.hostname);
  if (!target) {
    showError("Этот адрес не поддерживается");
    return;
  }

  const saved = await chrome.storage.local.get(storageKey(target));
  bypassed = saved[storageKey(target)] === true;
  setReadyLabel();
}

button.addEventListener("click", async () => {
  if (!target) {
    return;
  }

  button.disabled = true;
  button.dataset.error = "false";
  button.textContent = "Ожидание подтверждения Windows…";

  const action = bypassed ? "remove" : "add";
  try {
    const response = await chrome.runtime.sendNativeMessage(HOST_NAME, {
      action,
      target
    });

    if (!response?.ok) {
      throw new Error(response?.error || "Локальный компонент вернул ошибку");
    }

    bypassed = action === "add";
    await chrome.storage.local.set({ [storageKey(target)]: bypassed });
    setReadyLabel();
  } catch (error) {
    const message = String(error?.message || error);
    if (message.includes("host not found")) {
      showError("Сначала установите локальный компонент");
    } else if (message.includes("User cancelled") || message.includes("canceled")) {
      showError("Запрос администратора отменён");
    } else {
      showError(message.length > 70 ? "Не удалось изменить маршрут" : message);
    }
  }
});

initialize().catch(() => showError("Ошибка расширения"));
