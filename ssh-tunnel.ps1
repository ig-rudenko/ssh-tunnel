# Подключаем библиотеки для GUI
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Гарантируем, что PSScriptRoot корректный
if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

# Гарантируем, что HOME задан
if (-not $HOME) {
    $HOME = [Environment]::GetFolderPath("UserProfile")
}


# tun2socks относительно скрипта
$exePath = Join-Path $PSScriptRoot "tun2socks-windows-amd64.exe"
$configFile = Join-Path $PSScriptRoot "config.json"

$global:proc = $null
$global:sshProcess = $null

# ------------------ Загрузка и сохранение конфигурации ------------------

function Load-Config {
    if (Test-Path $configFile) {
        try {
            $json = Get-Content $configFile -Raw | ConvertFrom-Json
            return $json
        }
        catch {
            return $null
        }
    }
    return $null
}

function Save-Config {
    param($config)
    $config | ConvertTo-Json | Set-Content $configFile
}

# ------------------ Функции туннеля ------------------

function Interface-Exists {
    param($interface)
    return (netsh interface show interface | Select-String $interface)
}

function Start-Tunnel {
    param(
        $interface,
        $ip,
        $proxy_port,
        $ssh_user,
        $ssh_host,
        $ssh_port,
        $ssh_key_path
    )

    # Сохраняем параметры
    $cfg = [PSCustomObject]@{
        interface = $interface
        ip = $ip
        proxy_port = $proxy_port
        ssh_user = $ssh_user
        ssh_host = $ssh_host
        ssh_port = $ssh_port
        ssh_key_path = $ssh_key_path
    }
    Save-Config $cfg

    if ($global:proc -or $global:sshProcess) {
        [System.Windows.Forms.MessageBox]::Show("Туннель уже запущен!")
        return
    }

    # ------------------ SSH туннель ------------------
    try {
        $sshArgs = "-i `"$ssh_key_path`" -p $ssh_port -D $proxy_port -N $ssh_user@$ssh_host"
        $global:sshProcess = Start-Process -FilePath "ssh" -ArgumentList $sshArgs -NoNewWindow -PassThru
        Start-Sleep -Seconds 3
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Ошибка SSH: $_")
        return
    }

    # ------------------ Запуск tun2socks ------------------
    $global:proc = Start-Process -FilePath $exePath `
        -ArgumentList "--device tun://$interface --proxy socks5://127.0.0.1:$proxy_port" `
        -PassThru -NoNewWindow

    Start-Sleep -Seconds 2

    if (-not (Interface-Exists $interface)) {
        [System.Windows.Forms.MessageBox]::Show("Интерфейс $interface не появился!")
        Stop-Tunnel
        return
    }

    # Настройка IP
    $mask = "255.255.255.255"
    $ipCmd = "netsh interface ip set address name=`"$interface`" static $ip $mask"
    Invoke-Expression $ipCmd

    # Индекс интерфейса
    $ifIndex = (Get-NetAdapter | Where-Object {$_.Name -eq $interface}).ifIndex
    if (-not $ifIndex) {
        [System.Windows.Forms.MessageBox]::Show("Не удалось получить индекс интерфейса $interface!")
        Stop-Tunnel
        return
    }

    # Удаляем старый маршрут
    netsh interface ipv4 delete route 0.0.0.0/0 $ifIndex 2>$null

    # Добавляем маршрут с меткой 1
    $routeCmd = "netsh interface ipv4 add route 0.0.0.0/0 $ifIndex $ip metric=1"
    Invoke-Expression $routeCmd

    [System.Windows.Forms.MessageBox]::Show("CONNECTED")
    $status.Text = "CONNECTED"
}

function Stop-Tunnel {
    if ($global:proc) {
        $global:proc.Kill()
        $global:proc = $null
    }
    if ($global:sshProcess) {
        $global:sshProcess.Kill()
        $global:sshProcess = $null
    }
    $status.Text = "? DISCONNECTED"
}

# ------------------ GUI ------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "tun2ssh"
$form.Size = New-Object System.Drawing.Size(400,600)
$form.StartPosition = "CenterScreen"

# Загружаем конфиг
$config = Load-Config

# ------------------ Поля GUI ------------------
function Create-LabelTextBox($labelText, $y, $default) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $labelText
    $lbl.Location = New-Object System.Drawing.Point(20,$y)
    $lbl.AutoSize = $true
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Text = if ($config -and $config.$labelText) { $config.$labelText } else { $default }
    $txt.Location = New-Object System.Drawing.Point(150,$y)
    $txt.Width = 200
    return @($lbl,$txt)
}

# ------------------ Статус сверху ------------------
$status = New-Object System.Windows.Forms.Label
$status.Text = "DISCONNECTED"
$status.Font = New-Object System.Drawing.Font("Microsoft Sans Serif",12,[System.Drawing.FontStyle]::Regular)
$status.AutoSize = $true
$status.Location = New-Object System.Drawing.Point(140,10)
$status.ForeColor = [System.Drawing.Color]::Red
$form.Controls.Add($status)

# Поля
$fields = @()
$fields += ,(Create-LabelTextBox "interface" 50 "tun0")
$fields += ,(Create-LabelTextBox "ip" 90 "10.254.254.1")
$fields += ,(Create-LabelTextBox "proxy_port" 130 "1080")
$fields += ,(Create-LabelTextBox "ssh_user" 170 "user")
$fields += ,(Create-LabelTextBox "ssh_host" 210 "example.com")
$fields += ,(Create-LabelTextBox "ssh_port" 250 "22")
$fields += ,(Create-LabelTextBox "ssh_key_path" 290 "$HOME\.ssh\tun2socks_key")

# Распаковка для добавления в форму
$controls = @()
foreach ($f in $fields) { $controls += $f[0]; $controls += $f[1] }

# ------------------ Кнопки ------------------
$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = "CONNECT"
$btnConnect.Size = New-Object System.Drawing.Size(200,40)
$btnConnect.Location = New-Object System.Drawing.Point(100,340)
$btnConnect.Add_Click({
    $status.Text = "CONNECTING..."
    $status.ForeColor = [System.Drawing.Color]::Black
    $status.Font = New-Object System.Drawing.Font("Microsoft Sans Serif",12,[System.Drawing.FontStyle]::Regular)

    Start-Tunnel -interface $fields[0][1].Text `
                 -ip $fields[1][1].Text `
                 -proxy_port $fields[2][1].Text `
                 -ssh_user $fields[3][1].Text `
                 -ssh_host $fields[4][1].Text `
                 -ssh_port $fields[5][1].Text `
                 -ssh_key_path $fields[6][1].Text

    # Если Tunnel успешно подключён, обновляем статус
    if ($global:proc -and $global:sshProcess) {
        $status.Text = "CONNECTED"
        $status.ForeColor = [System.Drawing.Color]::DarkGreen
        $status.Font = New-Object System.Drawing.Font("Microsoft Sans Serif",12,[System.Drawing.FontStyle]::Bold)
    }
})

$btnDisconnect = New-Object System.Windows.Forms.Button
$btnDisconnect.Text = "DISCONNECT"
$btnDisconnect.Size = New-Object System.Drawing.Size(200,40)
$btnDisconnect.Location = New-Object System.Drawing.Point(100,380)
$btnDisconnect.Add_Click({
    Stop-Tunnel
    $status.Text = "DISCONNECTED"
    $status.ForeColor = [System.Drawing.Color]::Red
    $status.Font = New-Object System.Drawing.Font("Microsoft Sans Serif",12,[System.Drawing.FontStyle]::Regular)
})

# ------------------ Добавляем все контролы ------------------
$form.Controls.AddRange($controls + $btnConnect + $btnDisconnect)
$form.Add_FormClosing({ Stop-Tunnel })
$form.ShowDialog()