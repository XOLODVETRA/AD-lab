<#
.SYNOPSIS
    Создаёт или обновляет DHCP-scope для учебной сети и авторизует DHCP-сервер в AD.

.DESCRIPTION
    Проверяет наличие модуля DhcpServer, создаёт scope 192.168.10.0/24 (или обновляет
    уже существующий), настраивает опции 003 (маршрутизатор по умолчанию), 006 (DNS)
    и 015 (доменное имя), затем авторизует DHCP-сервер в Active Directory.
    Скрипт идемпотентен: повторный запуск обновляет параметры scope, а уже выполненная
    авторизация в AD не считается ошибкой.

.PARAMETER ScopeId
    Идентификатор scope — адрес подсети. По умолчанию: 192.168.10.0.

.PARAMETER StartRange
    Начало диапазона выдаваемых адресов. По умолчанию: 192.168.10.100.

.PARAMETER EndRange
    Конец диапазона выдаваемых адресов. По умолчанию: 192.168.10.150.

.PARAMETER SubnetMask
    Маска подсети. По умолчанию: 255.255.255.0.

.PARAMETER Router
    Адрес шлюза для опции 003. По умолчанию: 192.168.10.1.

.PARAMETER DnsServer
    Адрес DNS-сервера для опции 006 и адрес, под которым DHCP-сервер
    авторизуется в Active Directory. По умолчанию: 192.168.10.10.

.PARAMETER Domain
    Доменное имя для опции 015. По умолчанию: lab.local.

.EXAMPLE
    .\New-LabDhcpScope.ps1

    Создаёт scope 192.168.10.0 с диапазоном 192.168.10.100–192.168.10.150,
    опциями 003, 006, 015 и авторизует DHCP-сервер в домене lab.local.

.EXAMPLE
    .\New-LabDhcpScope.ps1 -ScopeId '192.168.20.0' -StartRange '192.168.20.100' -EndRange '192.168.20.150' -Router '192.168.20.1' -DnsServer '192.168.20.10' -Domain 'corp.local' -WhatIf

    Показывает, какие изменения были бы внесены, ничего не меняя.
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [string]$ScopeId = '192.168.10.0',

    [Parameter()]
    [string]$StartRange = '192.168.10.100',

    [Parameter()]
    [string]$EndRange = '192.168.10.150',

    [Parameter()]
    [string]$SubnetMask = '255.255.255.0',

    [Parameter()]
    [string]$Router = '192.168.10.1',

    [Parameter()]
    [string]$DnsServer = '192.168.10.10',

    [Parameter()]
    [string]$Domain = 'lab.local'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 1. Модуль DhcpServer
if (-not (Get-Module -ListAvailable -Name 'DhcpServer')) {
    $ErrorActionPreference = 'Continue'
    Write-Error 'Нужен модуль DhcpServer: запускайте на сервере с ролью DHCP.'
    exit 1
}

$scopeName = 'Lab ' + $ScopeId

try {
    # 2. Scope: создать или обновить
    $existingScope = Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction SilentlyContinue

    if ($null -eq $existingScope) {
        if ($PSCmdlet.ShouldProcess($ScopeId, 'Создать scope')) {
            Add-DhcpServerv4Scope -Name $scopeName -StartRange $StartRange -EndRange $EndRange -SubnetMask $SubnetMask -State Active
            Write-Verbose "Создан scope: $ScopeId"
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($ScopeId, 'Обновить scope')) {
            Set-DhcpServerv4Scope -ScopeId $ScopeId -StartRange $StartRange -EndRange $EndRange -SubnetMask $SubnetMask -State Active
            Write-Verbose "Обновлён scope: $ScopeId"
        }
    }

    # 3. Опции scope
    if ($PSCmdlet.ShouldProcess($ScopeId, 'Настроить опции 003, 006, 015')) {
        Set-DhcpServerv4OptionValue -ScopeId $ScopeId -OptionId '003' -Value $Router
        Set-DhcpServerv4OptionValue -ScopeId $ScopeId -OptionId '006' -Value $DnsServer
        Set-DhcpServerv4OptionValue -ScopeId $ScopeId -OptionId '015' -Value $Domain
        Write-Verbose 'Опции 003, 006 и 015 настроены.'
    }

    # 4. Авторизация DHCP-сервера в AD: повторный запуск не является ошибкой
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Авторизовать DHCP-сервер в AD')) {
        try {
            $authorizedServers = @(Get-DhcpServerInDC -ErrorAction Stop)
        }
        catch {
            $ErrorActionPreference = 'Continue'
            Write-Error ('Не удалось получить список авторизованных DHCP-серверов: ' + $_.Exception.Message)
            exit 1
        }

        $isAuthorized = $false
        foreach ($authorizedServer in $authorizedServers) {
            if ([string]$authorizedServer.IPAddress -eq [string]$DnsServer) {
                $isAuthorized = $true
                break
            }
        }

        if ($isAuthorized) {
            Write-Host 'DHCP-сервер уже авторизован в Active Directory.'
        }
        else {
            try {
                Add-DhcpServerInDC -DnsName $env:COMPUTERNAME -IPAddress $DnsServer -ErrorAction Stop
                Write-Verbose 'DHCP-сервер авторизован в Active Directory.'
            }
            catch {
                $ErrorActionPreference = 'Continue'
                Write-Error ('Не удалось авторизовать DHCP-сервер в Active Directory: ' + $_.Exception.Message)
                exit 1
            }
        }
    }
}
catch {
    $ErrorActionPreference = 'Continue'
    Write-Error ('Не удалось настроить scope: ' + $_.Exception.Message)
    exit 1
}

if ($WhatIfPreference) {
    Write-Host 'Режим -WhatIf: изменения не вносились.'
    Write-Host ("Был бы настроен scope {0}: диапазон {1}–{2}, DNS {3}, домен {4}" -f $ScopeId, $StartRange, $EndRange, $DnsServer, $Domain)
    exit 0
}

# 5. Итог
Write-Host "Scope $ScopeId готов: диапазон $StartRange–$EndRange, DNS $DnsServer, домен $Domain"
