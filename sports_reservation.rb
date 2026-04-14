require 'chrome_remote'

MAX_RETRIES = 100
RETRY_INTERVAL = 5
ERROR_CHECK_INTERVAL = 3

def wait_for_complete(chrome)
  loop do
    sleep 1
    response = chrome.send_cmd('Runtime.evaluate', expression: 'document.readyState')
    break if response.dig('result', 'value') == 'complete'
  end
  sleep 2
end

def js_eval(chrome, script)
  chrome.send_cmd('Runtime.evaluate', expression: script)
end

def click_with_xpath(chrome, xpath)
  result = js_eval(chrome, %Q{
    (function() {
      var node = document.evaluate(
        "#{xpath}",
        document,
        null,
        XPathResult.FIRST_ORDERED_NODE_TYPE,
        null
      ).singleNodeValue;

      if (!node) {
        throw new Error("XPath target not found: #{xpath}");
      }

      node.click();
      return true;
    })();
  })

  result
end

def click_by_id(chrome, id)
  result = js_eval(chrome, %Q{
    (function() {
      var el = document.getElementById("#{id}");
      if (!el) {
        throw new Error("Element not found: #{id}");
      }
      el.click();
      return true;
    })();
  })

  result
end

def is_error_page(chrome)
  result = js_eval(chrome, %q{
    (function() {
      return (
        document.title.includes('施設予約システムからのお知らせ') ||
        document.body.textContent.includes('ご迷惑をおかけしております') ||
        document.body.textContent.includes('現在、ご指定のページはアクセスできません')
      );
    })();
  })

  result.dig('result', 'value')
end

def reload_page(chrome)
  chrome.send_cmd('Page.reload')
  wait_for_complete(chrome)
end

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

  unless success
    raise "#{operation_name}が#{MAX_RETRIES}回の試行後も失敗しました。"
  end
end

at_exit do
  puts "Chromeプロセスを終了しています..."
  `pkill -f remote-debugging-port`
end

begin
  usr_dir_path = './chrome_usr_dir'
  `rm -rf #{usr_dir_path}`

  spawn("google-chrome --ozone-platform=x11 --window-size=1366,768 --no-sandbox --no-first-run --remote-debugging-port=9222 --user-data-dir=#{usr_dir_path} > /dev/null 2>&1")
  sleep 5

  chrome = ChromeRemote.client
  chrome.send_cmd('Page.enable')

  chrome.on('Page.javascriptDialogOpening') do |p|
    puts "JS dialog => #{p['message']}"
    chrome.send_cmd('Page.handleJavaScriptDialog', accept: true)
  end

  sports_url = 'https://kouen.sports.metro.tokyo.lg.jp/web/'

  retry_operation(chrome, 'サイトへのアクセス') do
    puts "#{sports_url}にアクセス中..."
    chrome.send_cmd('Page.navigate', url: sports_url)
  end

  current_url = js_eval(chrome, 'location.href').dig('result', 'value')
  puts "Current URL: #{current_url}"

  retry_operation(chrome, 'ログインボタンのクリック') do
    js_eval(chrome, %q{
      (function() {
        var loginBtn = document.getElementById('btn-login');
        if (!loginBtn) {
          throw new Error('btn-login not found');
        }
        loginBtn.click();
        return true;
      })();
    })
  end

  retry_operation(chrome, 'ログイン情報の入力') do
    js_eval(chrome, %q{
      (function() {
        var userIdField = document.getElementById('userId');
        var passwordField = document.getElementById('password');

        if (!userIdField || !passwordField) {
          throw new Error('login form not found');
        }

        userIdField.value = '10060973';
        passwordField.value = 'Yoshioka96';
        return true;
      })();
    })
  end

  retry_operation(chrome, 'ログイン送信') do
    js_eval(chrome, %q{
      (function() {
        var submitBtn = document.getElementById('btn-go');
        if (!submitBtn) {
          throw new Error('btn-go not found');
        }
        submitBtn.click();
        return true;
      })();
    })
  end

  retry_operation(chrome, '抽選タブのクリック') do
    js_eval(chrome, %q{
      (function() {
        var lotteryTab = Array.from(document.querySelectorAll('a.nav-link.dropdown-toggle'))
          .find(function(el) { return el.textContent.includes('抽選'); });

        if (!lotteryTab) {
          throw new Error('抽選タブが見つかりません');
        }

        lotteryTab.click();
        return true;
      })();
    })
  end

  retry_operation(chrome, '抽選申込みのクリック') do
    js_eval(chrome, %q{
      (function() {
        var entryLink = Array.from(document.querySelectorAll('a'))
          .find(function(el) { return el.textContent.trim() === '抽選申込み'; });

        if (!entryLink) {
          throw new Error('抽選申込みリンクが見つかりません');
        }

        entryLink.click();
        return true;
      })();
    })
  end

  retry_operation(chrome, '野球の申込みボタンをクリック') do
    js_eval(chrome, %q{
      (function() {
        var button = Array.from(document.querySelectorAll('td.request button')).find(function(btn) {
          var tr = btn.closest('tr');
          if (!tr) return false;
          var firstCell = tr.querySelector('td.sp-top');
          return firstCell && firstCell.textContent.trim().includes('野球');
        });

        if (!button) {
          throw new Error('野球の申込みボタンが見つかりません');
        }

        button.click();
        return true;
      })();
    })
  end

  sleep 2

  retry_operation(chrome, '野球場の選択') do
    js_eval(chrome, %q{
      (function() {
        var sel = document.getElementById('iname');
        if (!sel) {
          throw new Error('iname not found');
        }

        sel.value = '10100010';
        sel.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      })();
    })
  end

  sleep 2

  retry_operation(chrome, '日時チェックボックスのクリック') do
    js_eval(chrome, %q{
      (function() {
        var td = document.evaluate(
          "//tbody[contains(@class, 'text-center')]/tr/td[7]",
          document,
          null,
          XPathResult.FIRST_ORDERED_NODE_TYPE,
          null
        ).singleNodeValue;

        if (!td) {
          throw new Error('td not found');
        }

        var checkbox = td.querySelector('input[type="checkbox"]');
        if (!checkbox) {
          throw new Error('checkbox not found');
        }

        checkbox.click();
        return true;
      })();
    })
  end

  sleep 2

  retry_operation(chrome, '申込みボタンのクリック(1回目)') do
    js_eval(chrome, %q{
      (function() {
        var applicationBtn = document.getElementById('btn-go');
        if (!applicationBtn) {
          throw new Error('btn-go not found');
        }

        applicationBtn.click();
        return true;
      })();
    })
  end

  sleep 2

  retry_operation(chrome, '申し込み件数の選択') do
    js_eval(chrome, %q{
      (function() {
        var cell = document.getElementById('apply');
        if (!cell) {
          throw new Error('apply not found');
        }

        cell.value = '1-1';
        cell.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      })();
    })
  end

  sleep 2

  retry_operation(chrome, '申込みボタンのクリック(2回目)') do
    js_eval(chrome, %q{
      (function() {
        var applicationBtn = document.getElementById('btn-go');
        if (!applicationBtn) {
          throw new Error('btn-go not found');
        }

        applicationBtn.click();
        return true;
      })();
    })
  end

  after_lottery_entry_url = js_eval(chrome, 'location.href').dig('result', 'value')
  puts "URL after clicking '抽選申込み': #{after_lottery_entry_url}"

  puts '予約画面へのアクセスに成功しました！'
  puts 'Press Enter to close browser...'
  gets

rescue => e
  puts "エラーが発生しました: #{e.message}"
  puts e.backtrace
end