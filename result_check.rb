require 'chrome_remote'

# 設定値
MAX_RETRIES = 100            # 最大リトライ回数
RETRY_INTERVAL = 5          # リトライ間隔（秒）
ERROR_CHECK_INTERVAL = 3    # エラーチェック間隔（秒）

def wait_for_complete(chrome)
  loop do
    sleep(1)
    response = chrome.send_cmd 'Runtime.evaluate', expression: 'document.readyState;'
    break if response['result']['value'] == 'complete'
  end
  sleep(2)
end

def click_with_xpath(chrome, xpath)
  chrome.send_cmd('Runtime.evaluate', expression: "
    document.evaluate(
      \"#{xpath}\",
      document, null, XPathResult.FIRST_ORDERED_NODE_TYPE
    ).singleNodeValue.click();
  ")
end

def click_by_id(chrome, id)
  chrome.send_cmd('Runtime.evaluate', expression: "
    document.getElementById('#{id}').click();
  ")
end

# ページがアクセスできないエラー状態かをチェック
def is_error_page(chrome)
  result = chrome.send_cmd('Runtime.evaluate', expression: "
    (document.title.includes('施設予約システムからのお知らせ') ||
     document.body.textContent.includes('ご迷惑をおかけしております') ||
     document.body.textContent.includes('現在、ご指定のページはアクセスできません')) ? true : false;
  ")
  result['result']['value']
end

# ページをリロードする
def reload_page(chrome)
  chrome.send_cmd('Page.reload')
  wait_for_complete(chrome)
end

# リトライ可能な操作を実行する関数
def retry_operation(chrome, operation_name)
  retries = 0
  success = false

  while retries < MAX_RETRIES && !success
    begin
      if retries > 0
        puts "#{operation_name}: リトライ #{retries}/#{MAX_RETRIES}..."
      else
        puts "#{operation_name}を実行中..."
      end

      yield
      wait_for_complete(chrome)

      # エラーページかどうかチェック
      retry_count = 0
      while is_error_page(chrome) && retry_count < 3
        puts "アクセスエラーを検出。#{RETRY_INTERVAL}秒後にリロードします..."
        sleep(RETRY_INTERVAL)
        reload_page(chrome)
        retry_count += 1
      end

      if !is_error_page(chrome)
        puts "#{operation_name}: 成功"
        success = true
      else
        puts "#{operation_name}: エラーページが表示されています。リトライします。"
        sleep(RETRY_INTERVAL)
        retries += 1
      end
    rescue => e
      puts "#{operation_name}中にエラーが発生: #{e.message}"
      sleep(RETRY_INTERVAL)
      retries += 1
    end
  end

  if !success
    raise "#{operation_name}が#{MAX_RETRIES}回の試行後も失敗しました。"
  end
end

# 終了時にChromeを終了するための処理
at_exit do
  puts "Chromeプロセスを終了しています..."
  `pkill -f remote-debugging-port`
end

# メイン処理
begin
  # ユーザーディレクトリの設定
  usr_dir_path = './chrome_usr_dir'
  `rm -rf #{usr_dir_path}`
  spawn("google-chrome --window-size=1366,768 --no-sandbox --no-first-run --remote-debugging-port=9222 --user-data-dir=#{usr_dir_path} > /dev/null 2>&1")
  sleep 5

  chrome = ChromeRemote.client

  # 接続直後に
  chrome.send_cmd('Page.enable')

  # 以後、confirm/alert/prompt が出たら自動で OK（accept）する
  chrome.on('Page.javascriptDialogOpening') do |p|
    puts "JS dialog => #{p['message']}"
    chrome.send_cmd('Page.handleJavaScriptDialog', accept: true) # OKを押す
  end

  # 都立公園スポーツ予約システムのURLに遷移
  sports_url = 'https://kouen.sports.metro.tokyo.lg.jp/web/'

  retry_operation(chrome, "サイトへのアクセス") do
    puts "#{sports_url}にアクセス中..."
    chrome.send_cmd('Page.navigate', url: sports_url)
  end

  # 現在のURLを確認
  current_url = chrome.send_cmd('Runtime.evaluate', expression: 'location.href;')["result"]["value"]
  puts "Current URL: #{current_url}"

  # ログインボタンをクリック
  retry_operation(chrome, "ログインボタンのクリック") do
    puts "ログインボタンをクリック中..."
    chrome.send_cmd('Runtime.evaluate', expression: "
      var loginBtn = document.getElementById('btn-login');
      if (loginBtn) {
        loginBtn.click();
      }
    ")
  end

  # フォームに利用者番号とパスワードを入力
  retry_operation(chrome, "ログイン情報の入力") do
    puts "ログイン情報の入力中..."
    chrome.send_cmd('Runtime.evaluate', expression: "
      var userIdField = document.getElementById('userId');
      var passwordField = document.getElementById('password');

      if (userIdField && passwordField) {
        userIdField.value = '10056489';
        passwordField.value = '386475Tkp1';
      }
    ")
  end

  # 「ログイン」ボタンをクリック
  retry_operation(chrome, "ログイン送信") do
    chrome.send_cmd('Runtime.evaluate', expression: "
      var submitBtn = document.getElementById('btn-go');
      if (submitBtn) {
        submitBtn.click();
      }
    ")
  end

  # 抽選タブをクリック
  retry_operation(chrome, "抽選タブのクリック") do
    chrome.send_cmd('Runtime.evaluate', expression: "
      var lotteryTab = Array.from(document.querySelectorAll('a.nav-link.dropdown-toggle'))
        .find(el => el.textContent.includes('抽選'));
    ")
  end

  # 抽選申込みをクリック
  retry_operation(chrome, "抽選申込みのクリック") do
    chrome.send_cmd('Runtime.evaluate', expression: "
      var entryLink = Array.from(document.querySelectorAll('a'))
        .find(el => el.textContent.trim() === '抽選申込み');

      if (entryLink) {
        entryLink.click();
      }
    ")
  end

  # 「野球」の行にある［申込み］ボタンをクリック
  chrome.send_cmd(
    'Runtime.evaluate',
    expression: <<~JS
      (function() {
        // ① 申込みボタン群を全部列挙
        var button = Array.from(document.querySelectorAll('td.request button'))
          // ② ボタンに隣接する <tr> の先頭セルが「野球」かどうかで絞り込む
          .find(btn => {
            var tr = btn.closest('tr');
            if (!tr) return false;
            var firstCell = tr.querySelector('td.sp-top');
            return firstCell && firstCell.textContent.trim().includes('野球');
          });

        if (button) {
          button.click();
        }
      })();
    JS
  )

  # ページが完全に読み込まれるのを待つ
  sleep 2

  # 野球場(10100010)を選択して change を発火
  chrome.send_cmd(
    'Runtime.evaluate',
    expression: <<~'JS'
      (function(){
        var sel = document.getElementById('iname');
        sel.value = '10100010';
        sel.dispatchEvent(new Event('change', { bubbles: true }));
      })();
    JS
  )

  # ページが完全に読み込まれるのを待つ
  sleep 2

  # 日時チェックボックスをクリック
  chrome.send_cmd(
    'Runtime.evaluate',
    expression: <<~JS
      (function() {
        const td = document.evaluate(
          "//tbody[contains(@class, 'text-center')]/tr/td[7]",
          document,
          null,
          XPathResult.FIRST_ORDERED_NODE_TYPE,
          null
        ).singleNodeValue;
        if (!td) return "td not found";
        const checkbox = td.querySelector('input[type="checkbox"]');
        if (!checkbox) return "checkbox not found";
        checkbox.click();
        return "clicked";
      })();
    JS
  )

  # ページが完全に読み込まれるのを待つ
  sleep 2

  # 「申込み」ボタンをクリック
  chrome.send_cmd('Runtime.evaluate', expression: "
    var applicationBtn = document.getElementById('btn-go');
    if (applicationBtn) {
      applicationBtn.click();
    }
  ")

  # ページが完全に読み込まれるのを待つ
  sleep 2

  # 申し込み1件目を選択して change を発火
  chrome.send_cmd(
    'Runtime.evaluate',
    expression: <<~'JS'
      (function(){
        var cell = document.getElementById('apply');
        cell.value = '1-1';
        cell.dispatchEvent(new Event('change', { bubbles: true }));
      })();
    JS
  )

  # ページが完全に読み込まれるのを待つ
  sleep 2

  # 「申込み」ボタンをクリック
  chrome.send_cmd('Runtime.evaluate', expression: "
    var applicationBtn = document.getElementById('btn-go');
    if (applicationBtn) {
      applicationBtn.click();
    }
  ")

  # 遷移後のURLを確認
  after_lottery_entry_url = chrome.send_cmd('Runtime.evaluate', expression: 'location.href;')["result"]["value"]
  puts "URL after clicking '抽選申込み': #{after_lottery_entry_url}"

  # プログラムを終了せずにブラウザを開いたままにする
  puts "予約画面へのアクセスに成功しました！"
  puts "Press Enter to close browser..."
  gets

rescue => e
  puts "エラーが発生しました: #{e.message}"
  puts e.backtrace