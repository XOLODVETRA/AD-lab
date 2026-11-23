<#
.SYNOPSIS
    Создаёт учебных пользователей и группы из CSV-файла в домене Active Directory.

.DESCRIPTION
    Проверяет наличие модуля ActiveDirectory и домена, создаёт группы
    IT-Admins, IT-Helpdesk, Finance-Users, Sales-Users, Support-Users и VPN-Users,
    затем создаёт пользователей из CSV и добавляет их в группы.
    Скрипт идемпотентен: существующие пользователи пропускаются,
    уже имеющееся членство в группах повторно не добавляется.

.PARAMETER CsvPath
    Путь к CSV-файлу с пользователями. По умолчанию: .\data\users.csv.

.PARAMETER DomainDN
    Различающееся имя корня домена. По умолчанию: DC=lab,DC=local.

.PARAMETER DefaultPassword
    Пароль для новых учётных записей. Если не задан, запрашивается интерактивно.

.EXAMPLE
    .\New-LabUsers.ps1

    Создаёт пользователей из .\data\users.csv, пароль запрашивается интерактивно.

.EXAMPLE
    .\New-LabUsers.ps1 -CsvPath '.\data\users.csv' -WhatIf

    Показывает, какие пользователи были бы созданы, ничего не меняя.
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [string]$CsvPath = '.\data\users.csv',

    [Parameter()]
    [string]$DomainDN = 'DC=lab,DC=local',

    [Parameter()]
    [System.Security.SecureString]$DefaultPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 1. Модуль ActiveDirectory
if (-not (Get-Module -ListAvailable -Name 'ActiveDirectory')) {
    $ErrorActionPreference = 'Continue'
    Write-Error 'Нужен модуль ActiveDirectory: запускайте на контроллере домена или с RSAT.'
    exit 1
}

# 2. Домен
$domain = $null
try {
    $domain = Get-ADDomain -Identity $DomainDN -ErrorAction Stop
}
catch {
    $domain = $null
}

if ($null -eq $domain) {
    $ErrorActionPreference = 'Continue'
    Write-Error "Домен $DomainDN не найден."
    exit 1
}

$dnsSuffix = $domain.DNSRoot

# 3. CSV: файл и обязательные колонки
$requiredColumns = @('SamAccountName', 'GivenName', 'Surname', 'Department', 'Title', 'Groups', 'OU')

if (-not (Test-Path -Path $CsvPath -PathType Leaf)) {
    $ErrorActionPreference = 'Continue'
    Write-Error "Файл CSV не найден: $CsvPath"
    exit 1
}

$csvData = @()
try {
    $csvData = @(Import-Csv -Path $CsvPath -Encoding UTF8 -ErrorAction Stop)
}
catch {
    $csvData = @()
}

if ($csvData.Count -eq 0) {
    $ErrorActionPreference = 'Continue'
    Write-Error "В CSV нет строк с пользователями: $CsvPath"
    exit 1
}

$columns = $csvData[0].PSObject.Properties.Name
foreach ($requiredColumn in $requiredColumns) {
    if ($columns -notcontains $requiredColumn) {
        $ErrorActionPreference = 'Continue'
        Write-Error "В CSV нет колонки $requiredColumn"
        exit 1
    }
}

$groupNames = @('IT-Admins', 'IT-Helpdesk', 'Finance-Users', 'Sales-Users', 'Support-Users', 'VPN-Users')
$groupsOuDn = 'OU=Groups,OU=Lab,' + $DomainDN

$created = 0
$skipped = 0
$groupsCreated = 0

try {
    # 4. Группы
    foreach ($groupName in $groupNames) {
        $existingGroup = Get-ADGroup -Filter "SamAccountName -eq '$groupName'" -ErrorAction SilentlyContinue

        if ($null -ne $existingGroup) {
            Write-Verbose "Группа уже существует: $groupName"
            continue
        }

        if ($PSCmdlet.ShouldProcess($groupName, 'Создать группу')) {
            New-ADGroup -Name $groupName -SamAccountName $groupName -GroupScope Global -GroupCategory Security -Path $groupsOuDn
            $groupsCreated++
            Write-Verbose "Создана группа: $groupName"
        }
    }

    if ($null -eq $DefaultPassword) {
        $DefaultPassword = Read-Host -AsSecureString "Пароль для новых учётных записей"
    }

    # 5. Пользователи и 6. членство в группах
    foreach ($row in $csvData) {
        $sam = $row.SamAccountName.Trim()

        if ([string]::IsNullOrWhiteSpace($sam)) {
            $ErrorActionPreference = 'Continue'
            Write-Error 'В CSV пустое значение SamAccountName.'
            exit 1
        }

        $user = $null
        try {
            $user = Get-ADUser -Identity $sam -ErrorAction Stop
        }
        catch {
            $user = $null
        }

        if ($null -ne $user) {
            $skipped++
            Write-Verbose "Пользователь уже существует: $sam"
        }
        else {
            if (-not $PSCmdlet.ShouldProcess($sam, 'Создать пользователя')) {
                continue
            }

            $displayName = $row.GivenName.Trim() + ' ' + $row.Surname.Trim()
            $ouPath = $row.OU.Trim() + ',' + $DomainDN
            $userPrincipalName = $sam + '@' + $dnsSuffix

            $userParameters = @{
                Name                  = $displayName
                DisplayName           = $displayName
                GivenName             = $row.GivenName.Trim()
                Surname               = $row.Surname.Trim()
                Title                 = $row.Title.Trim()
                Department            = $row.Department.Trim()
                Path                  = $ouPath
                SamAccountName        = $sam
                UserPrincipalName     = $userPrincipalName
                AccountPassword       = $DefaultPassword
                Enabled               = $true
                ChangePasswordAtLogon = $true
            }

            New-ADUser @userParameters
            $created++
            Write-Verbose "Создан пользователь: $sam"

            $user = $null
            try {
                $user = Get-ADUser -Identity $sam -ErrorAction Stop
            }
            catch {
                $user = $null
            }

            if ($null -eq $user) {
                $ErrorActionPreference = 'Continue'
                Write-Error "Не удалось найти пользователя $sam после создания."
                exit 1
            }
        }

        $userDn = $user.DistinguishedName

        if ([string]::IsNullOrWhiteSpace($row.Groups)) {
            continue
        }

        foreach ($groupEntry in $row.Groups.Split(';')) {
            $groupName = $groupEntry.Trim()
            if ($groupName -eq '') {
                continue
            }

            $group = $null
            try {
                $group = Get-ADGroup -Identity $groupName -Properties Members -ErrorAction Stop
            }
            catch {
                $group = $null
            }

            if ($null -eq $group) {
                $ErrorActionPreference = 'Continue'
                Write-Error "Группа $groupName не найдена."
                exit 1
            }

            $members = @()
            if ($null -ne $group.PSObject.Properties['Members']) {
                $members = @($group.Members)
            }

            if ($members -contains $userDn) {
                Write-Verbose "Пользователь $sam уже состоит в группе $groupName"
                continue
            }

            if ($PSCmdlet.ShouldProcess($sam, "Добавить в группу $groupName")) {
                Add-ADGroupMember -Identity $groupName -Members $sam
                Write-Verbose "Пользователь $sam добавлен в группу $groupName"
            }
        }
    }
}
catch {
    $ErrorActionPreference = 'Continue'
    Write-Error ('Ошибка при создании объектов в AD: ' + $_.Exception.Message)
    exit 1
}

if ($WhatIfPreference) {
    Write-Host 'Режим -WhatIf: изменения не вносились.'
}

Write-Host ("Создано пользователей: {0}, пропущено: {1}, групп создано: {2}" -f $created, $skipped, $groupsCreated)
