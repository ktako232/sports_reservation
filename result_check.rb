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

  retry_operation(chrome, "予約ボタンのクリック") do
    chrome.send_cmd('Runtime.evaluate', expression: %q{
      (function() {
        var btn = document.querySelector('a[data-target="#modal-reservation-menus"]');
        btn.click();
        return true;
      })();
    })
  end

  retry_operation(chrome, "予約の確認のクリック") do
    chrome.send_cmd('Runtime.evaluate', expression: %q{
      (function() {
        var link = Array.from(document.querySelectorAll('a'))
          .find(function(el) {
            return el.textContent.trim() === '予約の確認';
          });

        if (!link) {
          throw new Error('予約の確認リンクが見つかりません');
        }

        link.click();
        return true;
      })();
    })
  end

  result = chrome.send_cmd('Runtime.evaluate', expression: %q{
    (function() {
      var rows = Array.from(document.querySelectorAll('#rsvacceptlist tbody tr')).slice(0, 10);
      var results = [];

      rows.forEach(function(row) {
        var text = row.innerText
          .replace(/\u00a0/g, ' ')
          .replace(/\s+/g, ' ')
          .trim();

        // ←ここが重要
        if (!text.includes('野球場')) return;

        var cells = row.querySelectorAll('td');

        var reservationId = cells[0].innerText.replace(/\s+/g, '').trim();

        var dateText = cells[1].innerText;
        var timeText = cells[2].innerText;
        var facilityText = cells[3].innerText;

        var dateMatch = dateText.match(/(\d+)月(\d+)日/);
        var times = Array.from(timeText.matchAll(/(\d{1,2})時(\d{2})分/g));

        if (!dateMatch || times.length < 2) return;

        var parkName = facilityText
          .replace(/\u00a0/g, ' ')
          .split(/\s+/)
          .filter(function(s) {
            return s && s !== '公園・施設：' && s !== '野球場';
          })[0] || '';

        results.push({
          reservation_id: reservationId,
          text:
            dateMatch[1] + '月' + dateMatch[2] + '日 ' +
            times[0][1] + ':' + times[0][2] + '~' +
            times[1][1] + ':' + times[1][2] + ' ' +
            parkName
        });
      });

      return results;
    })();
  })

values = result.dig('result', 'value') || []

if values.empty?
  puts "野球場の予約はなし"
else
  values.each { |v| puts v['text'] }
end

  values = result.dig('result', 'value') || []

  if values.empty?
    puts "野球場の予約はなし"
  else
    values.each do |item|
      puts "#{item['reservation_id']} #{item['text']}"
    end
  end

  puts '結果の確認に成功しました！'
  puts 'Press Enter to close browser...'
  gets

rescue => e
  puts "エラーが発生しました: #{e.message}"
  puts e.backtrace
end