const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const views = path.join(__dirname, '../files/luci/view/lite_ipam');
const template = fs.readFileSync(path.join(views, 'overview.htm'), 'utf8');
const ui = fs.readFileSync(path.join(views, 'ui.htm'), 'utf8');
const script = text => text.match(/<script type="text\/javascript">([\s\S]*?)<\/script>/)[1];
const rendered = template.replace(/<%[\s\S]*?%>/g, '/admin/services/lite-ipam/api/v1');

function fixture(level) {
    const health = {
        ok: level !== 'error', level, enabled: level !== 'disabled',
        message: level === 'error' ? '租约对账最近一次执行失败' : '后台检查通过，无待发布变更',
        sqlite_available: true, storage: {ok: true}, worker_running: true,
        issues: [], notices: [{title: '历史清理尚未执行', severity: 'info'}],
        history: [{title: '固定绑定发布已恢复', at: '2026-10-30T19:00:00Z',
            recovered_at: '2026-10-30T19:01:00Z', detail: 'previous error'}]
    };
    if (level === 'error') health.issues.push({
        title: health.message, severity: 'error', reason: '租约快照格式不正确',
        impact: '数据库中的有效租约可能不是最新快照。',
        at: '2026-10-30T19:02:00Z', action: '点击同步租约立即重试。',
        target: 'leases', detail: '<script>unexpected SQL error</script>'
    });
    if (level === 'warning') health.issues.push({
        title: '备份最近一次执行失败', severity: 'warning',
        impact: '不影响当前 DHCP', action: '检查空间后重试备份', target: 'settings'
    });
    if (level === 'pending') health.notices.push({
        title: '固定绑定有待发布变更', severity: 'pending', impact: '最新变更尚未生效'
    });
    if (level === 'disabled') health.message = '服务已禁用，不执行自动对账与发布';
    return {health, status: {enabled: health.enabled}, storage: {ok: true},
        backup: {ok: false, message: 'no status recorded'}};
}

async function check(level, actualHealth) {
    const elements = {};
    const requests = [];
    const data = fixture(level === 'empty-objects' ? 'ok' : level);
    if (actualHealth) data.health = actualHealth;
    if (level === 'empty-objects') {
        data.health.issues = {};
        data.health.notices = {};
        data.health.history = {};
        data.health.warnings = {};
    }
    const getElement = id => elements[id] || (elements[id] = {
        innerHTML: '', textContent: '', listeners: {},
        addEventListener(event, callback) { this.listeners[event] = callback; },
        click() { if (this.listeners.click) this.listeners.click({}); }
    });
    const context = {
        URLSearchParams, console,
        document: {getElementById: getElement, querySelectorAll: () => []},
        fetch: (url, options) => {
            requests.push({url, options});
            const body = url.includes('/overview/summary') ? data : url.endsWith('/leases/refresh') ? {ok: true} : [];
            return Promise.resolve({ok: true, json: () => Promise.resolve(body)});
        }
    };
    context.window = {setTimeout: () => 1, clearTimeout() {}};
    vm.createContext(context);
    vm.runInContext(script(ui), context);
    vm.runInContext(script(rendered), context);
    await new Promise(resolve => setImmediate(resolve));
    const html = getElement('lite-ipam-health-alerts').innerHTML;
    if (level === 'actual') {
        assert(html.includes(data.health.message));
        assert(getElement('lite-ipam-summary-board').innerHTML.includes(data.health.message));
        assert(getElement('lite-ipam-health').innerHTML.includes('整体状态'));
    } else if (level === 'empty-objects') {
        assert(html.includes('正常'));
        assert(!html.includes('历史异常'));
        assert(!html.includes('未执行项目'));
        assert(getElement('lite-ipam-summary-board').innerHTML.includes('后台检查通过'));
        assert(getElement('lite-ipam-health').innerHTML.includes('无当前故障或提醒'));
    } else {
        assert(html.includes('历史异常（1，不计入当前故障）'));
        assert(html.includes('<details class="lite-ipam-raw"><summary>历史异常'));
        assert(html.includes('未执行项目（1，不等于故障）'));
    }
    assert(!html.includes('<script>'));
    assert(!getElement('lite-ipam-message').innerHTML.includes('健康检查存在异常'));
    assert(!getElement('lite-ipam-message').innerHTML.includes('概览加载失败'));
    if (level === 'error') {
        for (const text of ['需要处理', '租约对账最近一次执行失败', '原因：', '影响：', '最近发生：', '建议：', '&lt;script&gt;'])
            assert(html.includes(text), text);
        getElement('lite-ipam-health-alerts').listeners.click({
            target: {getAttribute: () => '1'}
        });
        await new Promise(resolve => setImmediate(resolve));
        assert(requests.some(r => r.url.endsWith('/leases/refresh') && r.options.method === 'POST'));
    }
    if (level === 'warning') assert(html.includes('需关注') && html.includes('/lite-ipam/settings'));
    if (level === 'pending') assert(html.includes('处理中') && html.includes('固定绑定有待发布变更'));
    if (level === 'disabled') assert(html.includes('已禁用') && !html.includes('需要处理'));
    if (level === 'ok') assert(html.includes('正常') && !html.includes('需要处理'));
}

if (process.argv[2] === '--preview') {
    const mock = `<script>fetch = function(url) { return Promise.resolve({ok:true,json:function() {
        return Promise.resolve(url.indexOf('/overview/summary') >= 0 ? ${JSON.stringify(fixture('error')).replace(/</g, '\\u003c')} : []);
    }}); };</script>`;
    process.stdout.write('<!doctype html><meta charset="utf-8">' +
        fs.readFileSync(path.join(views, 'style.htm'), 'utf8') + mock + ui + rendered);
} else {
    (async () => {
        if (process.argv[2] === '--health-json')
            await check('actual', JSON.parse(fs.readFileSync(process.argv[3], 'utf8')));
        else
            for (const level of ['ok', 'error', 'warning', 'pending', 'disabled', 'empty-objects']) await check(level);
        console.log('Overview rendering and retry scenarios passed');
    })().catch(error => { console.error(error); process.exitCode = 1; });
}
