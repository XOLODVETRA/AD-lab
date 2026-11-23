# Гайд: от пустой VMware до зелёной проверки

Пошаговая инструкция по сборке стенда `ad-lab` с нуля. Все команды проверены на Windows Server 2022,
PowerShell 5.1, VMware Workstation. Время: 40–60 минут, из них половина — установка Windows.

В тексте есть блоки «Если сломалось» — это реальные ошибки, которые возникают чаще всего, с готовым
решением. Читайте их до того, как начнёте гуглить.

**Что понадобится:** ISO Windows Server 2022 Evaluation (Desktop Experience), VMware Workstation,
хост с 8 ГБ RAM и 80 ГБ свободного места, ISO Windows 11 для клиента (можно позже).

---

## 1. Виртуальная машина

`File → New Virtual Machine → Typical`:

| Параметр | Значение |
| --- | --- |
| Installer disc image | ISO Windows Server 2022 |
| Name | `DC01` |
| Disk size | 60 GB (не «Split virtual disk») |
| Memory | 4096 MB |
| Processors | 2 |
| Network Adapter | **Custom → VMnet1** |
| CD/DVD | ISO подключён |

Память и сеть можно поменять позже в `VM → Settings`, но только при выключенной машине
(сеть — можно и на ходу).

### Сеть VMnet1: подсеть и DHCP

`Edit → Virtual Network Editor → Change Settings` (нужны права администратора, иначе поля серые):

- выберите **VMnet1**
- **Subnet IP** `192.168.10.0`, **Subnet mask** `255.255.255.0`
- снимите **Use local DHCP service** — адреса будет выдавать контроллер домена
- **Apply → OK**

Проверка на хосте (cmd): `ipconfig` → у «VMware Network Adapter VMnet1» адрес `192.168.10.1`.

> **Если сломалось: в настройках ВМ в поле сети бесконечно висит «Loading virtual networks…»**
> Упала служба VMware DHCP. Проверьте `services.msc` → «VMware DHCP Service» (`VMnetDHCP`).
> Если она остановлена, а конфиг `C:\ProgramData\VMware\vmnetdhcp.conf` отсутствует — служба не
> запустится. Восстановить проще всего переустановкой VMware с опцией Repair; в крайнем случае
> служба не нужна вообще: для host-only сети DHCP выключен, а NAT-машины можно перевести на
> статические адреса.

> **Если сломалось: ВМ не пингует хост, ошибка `DestinationHostUnreachable`**
> Адаптер ВМ стоит в режиме NAT, а не на VMnet1. `VM → Settings → Network Adapter →
> Custom: Specific virtual network → VMnet1`. Проверить можно и по файлу `.vmx`:
> строка `ethernet0.connectionType` должна быть `"custom"`, а `ethernet0.vnet = "vmnet1"`.

---

## 2. Установка Windows Server

Стандартная установка, редакция **Standard (Desktop Experience)**. Язык и раскладку выбирайте
любые — на команды это не влияет.

При первом входе Windows попросит задать пароль администратора — **не пропускайте этот шаг**.

> **Если сломалось: `Install-ADDSForest` падает с «пароль для локальной учетной записи
> администратора не соответствует требованиям»**
> У локального `Administrator` пустой пароль, а повышение до контроллера домена этого не
> допускает. Задайте пароль:
> ```powershell
> $adminPw = Read-Host -AsSecureString 'Пароль локального Administrator'
> Set-LocalUser -Name 'Administrator' -Password $adminPw
> ```
> Требования: 7+ символов, заглавная, строчная, цифра — например `Lab2026!Adm`.

Дальше все команды — в **PowerShell от имени администратора** (правый клик по «Пуск» →
«Windows PowerShell (администратор)» или «Терминал (администратор)»).

---

## 3. Имя, адрес, DNS

```powershell
$nic = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).Name
Write-Host "Адаптер: $nic"

Set-NetIPInterface -InterfaceAlias $nic -Dhcp Disabled
New-NetIPAddress -InterfaceAlias $nic -IPAddress '192.168.10.10' -PrefixLength 24
Set-DnsClientServerAddress -InterfaceAlias $nic -ServerAddresses '192.168.10.10'
Rename-Computer -NewName 'DC01' -Restart
```

**Что делает.** Статический адрес без шлюза (в host-only сети шлюза нет), DHCP на адаптере
выключен, DNS указывает на себя, машина переименовывается в `DC01` и перезагружается.

**Проверка после перезагрузки:**

```powershell
Get-NetIPAddress -InterfaceAlias $nic -AddressFamily IPv4 | Select-Object IPAddress, PrefixLength, PrefixOrigin
Get-NetIPInterface -InterfaceAlias $nic -AddressFamily IPv4 | Select-Object Dhcp
hostname
```

Ожидается `192.168.10.10`, `Manual`, `Dhcp: Disabled`, `DC01`.

> **Если сломалось: пинг до хоста не проходит, в `Test-NetConnection` видно чужой `SourceAddress`**
> На адаптере остался старый адрес (например, от DHCP). Посмотрите список и удалите лишний:
> ```powershell
> Get-NetIPAddress -InterfaceAlias $nic -AddressFamily IPv4 | Select-Object IPAddress, PrefixOrigin
> Remove-NetIPAddress -InterfaceAlias $nic -IPAddress '192.168.51.20' -Confirm:$false
> ```

---

## 4. Роль AD DS и лес

```powershell
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

$dsrm = Read-Host -AsSecureString 'Пароль DSRM'
Install-ADDSForest -DomainName 'lab.local' -DomainNetbiosName 'LAB' -InstallDns -SafeModeAdministratorPassword $dsrm -Force
```

**Что делает.** Ставит роль доменных служб с консолями и модулем PowerShell, затем создаёт лес
`lab.local` и повышает машину до контроллера домена. Пароль DSRM — аварийный, для восстановления
служб каталогов; запишите его отдельно от пароля администратора.

Машина перезагрузится сама. Вход после перезагрузки — `LAB\Administrator`.

**Проверка:**

```powershell
Get-ADDomain | Select-Object DNSRoot, NetBIOSName
Get-Service NTDS, DNS, Netlogon | Select-Object Name, Status
```

Ожидается `lab.local`, `LAB` и три службы `Running`.

---

## 5. Обратная зона DNS

```powershell
Add-DnsServerPrimaryZone -NetworkId '192.168.10.0/24' -ReplicationScope 'Domain'
```

**Что делает.** Создаёт зону обратного просмотра `10.168.192.in-addr.arpa` для PTR-записей.
Прямая зона `lab.local` уже создана вместе с лесом.

Forwarders (`Add-DnsServerForwarder -IPAddress '8.8.8.8'`) нужны только если у ВМ есть интернет;
в host-only сети их пропускают — внешний DNS стенду не требуется.

**Проверка:**

```powershell
Get-DnsServerZone | Select-Object ZoneName, ZoneType, IsDsIntegrated
Resolve-DnsName 'DC01'
Resolve-DnsName '192.168.10.10'
```

Должны быть обе зоны, A-запись `192.168.10.10` и PTR `DC01.lab.local`.

---

## 6. Роль DHCP

```powershell
Install-WindowsFeature -Name DHCP -IncludeManagementTools
Add-DhcpServerSecurityGroup
Restart-Service DHCPServer -ErrorAction SilentlyContinue
```

**Что делает.** Ставит роль DHCP и создаёт группу безопасности `DHCP Administrators` с нужными
правами. Сам scope настраивает скрипт из репозитория (шаг 8) — или руками, если скриптов под рукой
нет:

```powershell
Add-DhcpServerv4Scope -Name 'Lab 192.168.10.0' -StartRange '192.168.10.100' -EndRange '192.168.10.150' -SubnetMask '255.255.255.0' -State Active
Set-DhcpServerv4OptionValue -ScopeId '192.168.10.0' -OptionId '003' -Value '192.168.10.1'
Set-DhcpServerv4OptionValue -ScopeId '192.168.10.0' -OptionId '006' -Value '192.168.10.10'
Set-DhcpServerv4OptionValue -ScopeId '192.168.10.0' -OptionId '015' -Value 'lab.local'
Add-DhcpServerInDC -DnsName 'DC01.lab.local' -IPAddress '192.168.10.10'
```

> Шлюз `192.168.10.1` в host-only сети недоступен — так и задумано, домену это не мешает:
> весь трафик идёт внутри подсети.

---

## 7. Как положить репозиторий на DC01

Интернета на стенде нет, `git clone` не сработает. Варианты:

**Общая папка VMware.** На хосте: `VM → Settings → Options → Shared Folders → Always enabled →
Add` → путь к папке с репозиторием, имя `adlab`. В ВМ:

```powershell
Copy-Item '\\vmware-host\Shared Folders\adlab' C:\ad-lab -Recurse
```

Общая папка требует установленных VMware Tools (обычно ставятся вместе с системой; если нет —
`VM → Install VMware Tools`, ISO монтируется автоматически, интернет не нужен).

**Архив.** Скачать ZIP репозитория на хосте, положить в общую папку или примонтировать как ISO,
в ВМ распаковать:

```powershell
Expand-Archive C:\ad-lab.zip C:\ad-lab -Force
```

**HTTP с хоста.** Если ВМ уже в сети `192.168.10.0/24`, а на хосте запущен веб-сервер:

```powershell
Invoke-WebRequest 'http://192.168.10.1:8000/ad-lab.zip' -OutFile C:\ad-lab.zip
Expand-Archive C:\ad-lab.zip C:\ad-lab -Force
```

Проверка: `Get-ChildItem C:\ad-lab` → `README.md`, `LICENSE`, `data`, `docs`, `scripts`.

---

## 8. Скрипты лаборатории

Порядок важен: каждый следующий опирается на предыдущий.

```powershell
cd C:\ad-lab
Set-ExecutionPolicy -Scope Process Bypass -Force

.\scripts\New-LabOUs.ps1
$pw = Read-Host -AsSecureString 'Пароль для 8 учебных учёток'
.\scripts\New-LabUsers.ps1 -DefaultPassword $pw
.\scripts\New-LabDhcpScope.ps1
.\scripts\Test-Lab.ps1
```

**Ожидаемый результат после каждого:**

| Скрипт | Что увидите |
| --- | --- |
| `New-LabOUs.ps1` | `Создано подразделений: 10, уже было: 0` |
| `New-LabUsers.ps1` | `Создано пользователей: 8, пропущено: 0, групп создано: 6` |
| `New-LabDhcpScope.ps1` | `Scope 192.168.10.0 готов: диапазон 192.168.10.100–192.168.10.150, DNS 192.168.10.10, домен lab.local` |
| `Test-Lab.ps1` | таблица из 6 строк `OK` и `Итог: 6 из 6 проверок пройдено` |

Все скрипты идемпотентны: повторный запуск печатает `0 создано` и ничего не дублирует. Проверить
это можно сразу — запустите любой из них второй раз.

---

## 9. Клиент в домене

Вторая ВМ: Windows 11, сеть **Custom → VMnet1**, ничего больше настраивать не нужно — адрес и DNS
придут по DHCP.

```powershell
ipconfig /renew
ipconfig /all
```

Ожидается адрес из `192.168.10.100–150`, DNS `192.168.10.10`, суффикс `lab.local`.

Ввод в домен:

```powershell
Add-Computer -DomainName 'lab.local' -Credential (Get-Credential) -Restart
```

В окне учётных данных — `LAB\Administrator` и его пароль. После перезагрузки вход как
`LAB\i.petrov` (пароль, который задавали для учебных учёток; при первом входе попросит сменить).

Проверка:

```powershell
whoami
nslookup lab.local
```

Ожидается `lab\i.petrov` и адрес контроллера домена в ответе.

---

## 10. Частые ошибки

| Симптом | Причина | Что делать |
| --- | --- | --- |
| `Install-ADDSForest`: пароль локального администратора не соответствует требованиям | у `Administrator` пустой пароль | `Set-LocalUser -Name 'Administrator' -Password $pw` и повторить |
| `DestinationHostUnreachable` при обращении к хосту | адаптер ВМ в режиме NAT | переключить на `Custom → VMnet1` |
| «Loading virtual networks…» в настройках ВМ | служба `VMnetDHCP` не запущена | запустить службу или переустановить VMware (Repair) |
| `Подразделение не найдено: OU=…` | не выполнен `New-LabOUs.ps1` или другой `-DomainDN` | запустить `New-LabOUs.ps1`, затем повторить |
| `Нужен модуль DhcpServer` | не установлена роль DHCP | шаг 6 |
| Клиент не получает адрес, остаётся `169.254.x.x` | DHCP не авторизован в AD | `Add-DhcpServerInDC` или `New-LabDhcpScope.ps1` |
| `Get-DhcpServerv4Scope` показывает `Inactive` | scope выключен | `Set-DhcpServerv4Scope -ScopeId '192.168.10.0' -State Active` |
| Вход в домен падает с ошибкой Kerberos про время | расхождение времени больше 5 минут | `w32tm /resync` на DC и на клиенте |
| Клиент не видит домен, `nslookup` не отвечает | в DNS клиента не `192.168.10.10` | проверить опцию 006 и `ipconfig /all` |

---

## 11. Что дальше

Стенд закрывает базу: домен, DNS, DHCP, OU, массовое создание учёток. Логичные следующие шаги —
групповые политики (парольная политика, запрет USB), вторая ВМ с ролью DNS или RODC, резервное
копирование состояния контроллера домена (`wbadmin`), мониторинг служб. Каждый шаг стоит оформлять
так же: команда → что делает → как проверить.
