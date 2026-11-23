<#
.SYNOPSIS
    Проверяет работоспособность учебной лаборатории: домен, DNS, DHCP и группы.

.DESCRIPTION
    Выполняет пять проверок: доступность домена Active Directory, наличие зоны DNS,
    разрешение имени контроллера домена, активность DHCP-scope и состав группы IT-Admins.
    Каждая проверка выполняется изолированно: ошибка одной не мешает остальным,
    а причина попадает в колонку «Детали».
    Результат выводится таблицей. Если хотя бы одна проверка не пройдена,
    скрипт завершается с кодом 1, иначе — с кодом 0.

.PARAMETER DomainDN
    Различающееся имя корня домена. По умолчанию: DC=lab,DC=local.

.PARAMETER DcName
    Имя контроллера домена, которое должно резолвиться в IP-адрес. По умолчанию: DC01.

.PARAMETER ScopeId
    Идентификатор проверяемого DHCP-scope. По умолчанию: 192.168.10.0.

.EXAMPLE
    .\Test-Lab.ps1

    Проверяет домен lab.local, контроллер DC01 и scope 192.168.10.0.

.EXAMPLE
    .\Test-Lab.ps1 -DomainDN 'DC=corp,DC=local' -DcName 'DC02' -ScopeId '192.168.20.0'

    Проверяет другой домен, другой контроллер домена и другой scope.
#>
param(
    [Parameter()]
    [string]$DomainDN = 'DC=lab,DC=local',

    [Parameter()]
    [string]$DcName = 'DC01',

    [Parameter()]
    [string]$ScopeId = '192.168.10.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 0. Модули
$requiredModules = @('ActiveDirectory', 'DnsServer', 'DhcpServer')
$missingModules = @()

foreach ($moduleName in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        $missingModules += $moduleName
    }
}

if ($missingModules.Count -gt 0) {
    $ErrorActionPreference = 'Continue'
    Write-Error ('Нет модулей: ' + ($missingModules -join ', ') + '. Нужен контроллер домена с ролями AD DS, DNS и DHCP (или RSAT).')
    exit 1
}

# DNS-имя домена для проверки зоны: DC=lab,DC=local -> lab.local
$dnsDomainName = (($DomainDN -split ',') | ForEach-Object { ($_.Trim() -replace '^[Dd][Cc]=', '') }) -join '.'

# Причина сбоя — одной строкой, чтобы таблица не расползалась
function Get-OneLineCause {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message
    )

    return ($Message -replace '\s+', ' ').Trim()
}

$results = @()

# 1. Домен доступен
try {
    $domain = Get-ADDomain -Identity $DomainDN -ErrorAction Stop
    $results += [pscustomobject]@{
        Проверка = 'Домен доступен'
        Статус   = 'OK'
        Детали   = ('Домен: ' + $domain.DNSRoot)
    }
}
catch {
    $results += [pscustomobject]@{
        Проверка = 'Домен доступен'
        Статус   = 'FAIL'
        Детали   = ('Домен ' + $DomainDN + ' недоступен: ' + (Get-OneLineCause -Message $_.Exception.Message))
    }
}

# 2. Зона DNS есть
try {
    $zone = Get-DnsServerZone -Name $dnsDomainName -ErrorAction Stop
    $results += [pscustomobject]@{
        Проверка = 'Зона DNS есть'
        Статус   = 'OK'
        Детали   = ('Зона: ' + $zone.ZoneName + ', тип ' + $zone.ZoneType)
    }
}
catch {
    $results += [pscustomobject]@{
        Проверка = 'Зона DNS есть'
        Статус   = 'FAIL'
        Детали   = ('Зона ' + $dnsDomainName + ' не найдена на DNS-сервере: ' + (Get-OneLineCause -Message $_.Exception.Message))
    }
}

# 3. Имя DC резолвится
try {
    $dnsRecords = @(Resolve-DnsName -Name $DcName -ErrorAction Stop)
    $firstIp = $null

    foreach ($record in $dnsRecords) {
        if ($null -ne $record.PSObject.Properties['IPAddress']) {
            if (-not [string]::IsNullOrEmpty($record.IPAddress)) {
                $firstIp = $record.IPAddress
                break
            }
        }
    }

    if ($null -eq $firstIp) {
        throw 'A-запись не найдена'
    }

    $results += [pscustomobject]@{
        Проверка = 'Имя DC резолвится'
        Статус   = 'OK'
        Детали   = ($DcName + ' -> ' + $firstIp)
    }
}
catch {
    $results += [pscustomobject]@{
        Проверка = 'Имя DC резолвится'
        Статус   = 'FAIL'
        Детали   = ('Имя ' + $DcName + ' не разрешается через DNS: ' + (Get-OneLineCause -Message $_.Exception.Message))
    }
}

# 4. Scope активен
try {
    $scope = Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction Stop

    if ($scope.State -eq 'Active') {
        $results += [pscustomobject]@{
            Проверка = 'Scope активен'
            Статус   = 'OK'
            Детали   = ('Scope ' + $ScopeId + ': ' + $scope.State)
        }
    }
    else {
        $results += [pscustomobject]@{
            Проверка = 'Scope активен'
            Статус   = 'FAIL'
            Детали   = ('Scope ' + $ScopeId + ': ' + $scope.State)
        }
    }
}
catch {
    $results += [pscustomobject]@{
        Проверка = 'Scope активен'
        Статус   = 'FAIL'
        Детали   = ('Scope ' + $ScopeId + ' не найден или DHCP недоступен: ' + (Get-OneLineCause -Message $_.Exception.Message))
    }
}

# 5. В группе IT-Admins есть участники
try {
    $memberCount = @(Get-ADGroupMember -Identity 'IT-Admins' -ErrorAction Stop).Count

    if ($memberCount -gt 0) {
        $status = 'OK'
    }
    else {
        $status = 'FAIL'
    }

    $results += [pscustomobject]@{
        Проверка = 'В группе IT-Admins есть участники'
        Статус   = $status
        Детали   = ('Участников: ' + $memberCount)
    }
}
catch {
    $results += [pscustomobject]@{
        Проверка = 'В группе IT-Admins есть участники'
        Статус   = 'FAIL'
        Детали   = ('Группа IT-Admins недоступна: ' + (Get-OneLineCause -Message $_.Exception.Message))
    }
}

$results | Format-Table -AutoSize

$total = $results.Count
$passed = @($results | Where-Object { $_.'Статус' -eq 'OK' }).Count

Write-Output ("Итог: {0} из {1} проверок пройдено" -f $passed, $total)

if ($passed -lt $total) {
    exit 1
}

exit 0
