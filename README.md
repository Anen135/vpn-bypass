<div align="center">
  <img src="docs/icon.png" width="128" height="128" alt="VPN Bypass">
  <h1>VPN Bypass</h1>
  <p>Расширение Chrome/Edge для прямого доступа к выбранным сайтам в обход системного VPN на Windows.</p>

  [![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
  ![Platform](https://img.shields.io/badge/platform-Windows-0078D4)
  ![Chrome MV3](https://img.shields.io/badge/Chrome-Manifest%20V3-4285F4)
</div>

> [!IMPORTANT]
> Это экспериментальный инструмент для IP-маршрутизации, а не полноценный доменный split tunneling. Перед установкой прочитайте раздел [«Ограничения»](#ограничения).

## Как это работает

Откройте сайт и нажмите кнопку расширения:

- **Отключить VPN для этого сайта** — IP-адреса текущего hostname направляются через физический сетевой адаптер;
- **Включить VPN для этого сайта** — созданные расширением маршруты удаляются.

Браузер не может самостоятельно запускать PowerShell или изменять системные маршруты. Поэтому проект состоит из трёх частей:

```mermaid
flowchart LR
    A[Popup расширения] -->|hostname + add/remove| B[Native Messaging host]
    B -->|UAC / проверенные аргументы| C[PowerShell]
    C --> D[Таблица маршрутизации Windows]
```

Native host принимает только действия `add` и `remove`, повторно проверяет доменное имя и передаёт аргументы PowerShell без построения командной строки из пользовательского ввода. Все операции выполняются локально; проект не отправляет историю сайтов или настройки на внешний сервер.

## Требования

- Windows 10 или Windows 11;
- Google Chrome или Microsoft Edge;
- .NET SDK 10 для сборки локального Native Messaging host;
- права администратора для добавления и удаления маршрутов;
- VPN с отдельным виртуальным адаптером и доступный физический IPv4/IPv6-шлюз.

## Установка

### 1. Клонируйте репозиторий

```powershell
git clone https://github.com/Anen135/vpn-bypass.git
cd vpn-bypass
```

### 2. Загрузите расширение

1. Откройте `chrome://extensions` или `edge://extensions`.
2. Включите **Режим разработчика**.
3. Нажмите **Загрузить распакованное расширение**.
4. Выберите папку `extension` из репозитория.
5. Проверьте ID: `alhckcekmoalpnnpokflgpkajcpdbdfi`.

Поле `key` в `manifest.json` фиксирует ID, который разрешён в конфигурации Native Messaging host.

### 3. Установите локальный компонент

Запустите из корня репозитория:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-NativeHost.ps1
```

Установщик:

1. собирает автономный `VpnBypass.NativeHost.exe`;
2. копирует host и PowerShell-скрипт в `%LOCALAPPDATA%\VpnBypass\NativeHost`;
3. регистрирует host для Chrome и Edge в `HKCU`;
4. не требует установки .NET Runtime для последующего запуска.

Перезапустите браузер после установки. При изменении маршрута Windows покажет UAC — `New-NetRoute` и `Remove-NetRoute` требуют прав администратора.

## Использование

1. Подключите VPN.
2. Откройте обычную `http`/`https`-страницу.
3. Нажмите значок VPN Bypass.
4. Нажмите **Отключить VPN для этого сайта** и подтвердите UAC.
5. Чтобы вернуть трафик сайта в VPN, откройте popup повторно и нажмите **Включить VPN для этого сайта**.

Сведения о созданных маршрутах хранятся в `%ProgramData%\VpnBypassManager\routes.json`. Менеджер удаляет только маршруты, которые считает созданными этим приложением.

## Ограничения

Windows выбирает маршрут по IP-префиксу, а не по доменному имени. Расширение разрешает текущий hostname через DNS и создаёт маршруты `/32` для IPv4 и `/128` для IPv6. Из этого следуют ограничения:

- маршруты не обновляются автоматически при смене DNS-адресов;
- ресурсы с других hostname продолжают идти по обычному маршруту;
- один IP может обслуживать несколько несвязанных сайтов;
- `youtube.com` не охватывает автоматически `googlevideo.com`, `ytimg.com` и другие CDN-домены;
- VPN-клиент или корпоративная политика могут блокировать трафик вне туннеля независимо от таблицы маршрутизации.

Для надёжного доменного split tunneling используйте правила самого VPN-клиента, локальный прокси или службу, которая постоянно отслеживает DNS и соединения.

## Удаление

Сначала включите VPN обратно для всех сайтов, отмеченных как обходящие VPN. Затем выполните:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Uninstall-NativeHost.ps1
```

После этого удалите расширение на странице `chrome://extensions` или `edge://extensions`.

Если Native host уже удалён, но маршруты остались, проверьте `%ProgramData%\VpnBypassManager\routes.json` и удалите соответствующие маршруты вручную через `Remove-NetRoute` от имени администратора.

## Разработка

```powershell
dotnet build .\native-host\VpnBypass.NativeHost.csproj --configuration Release
node --check .\extension\popup.js
```

Структура проекта:

| Путь | Назначение |
| --- | --- |
| `extension/` | Manifest V3, popup и иконки расширения |
| `native-host/` | .NET Native Messaging host и PowerShell-менеджер маршрутов |
| `scripts/` | установка и удаление Native Messaging host |
| `assets/` | исходник иконки проекта |

## Лицензия

Copyright © 2026 Anen135.

VPN Bypass распространяется на условиях [GNU General Public License v3.0](LICENSE). Производные работы при распространении должны сохранять условия GPL-3.0 и предоставлять исходный код.
