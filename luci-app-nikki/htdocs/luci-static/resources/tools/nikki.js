'use strict';
'require baseclass';
'require uci';
'require fs';
'require rpc';
'require request';

const callRCList = rpc.declare({
    object: 'rc',
    method: 'list',
    params: ['name'],
    expect: { '': {} }
});

const callRCInit = rpc.declare({
    object: 'rc',
    method: 'init',
    params: ['name', 'action'],
    expect: { '': {} }
});

const nikkiHelper = '/usr/libexec/nikki-rpc';

function callNikki(action, args) {
    const params = [action].concat(args || []).map(function (value) {
        return (value == null) ? '' : String(value);
    });

    return fs.exec(nikkiHelper, params).then(function (result) {
        if (result.code !== 0)
            throw new Error(result.stderr || result.stdout || _('Nikki helper failed'));

        try {
            return JSON.parse(result.stdout || '{}');
        } catch (e) {
            throw new Error(_('Invalid response from Nikki helper'));
        }
    });
}

const homeDir = '/etc/nikki';
const profilesDir = `${homeDir}/profiles`;
const subscriptionsDir = `${homeDir}/subscriptions`;
const mixinFilePath = `${homeDir}/mixin.yaml`;
const runDir = `${homeDir}/run`;
const runProfilePath = `${runDir}/config.yaml`;
const providersDir = `${runDir}/providers`;
const ruleProvidersDir = `${providersDir}/rule`;
const proxyProvidersDir = `${providersDir}/proxy`;
const logDir = `/var/log/nikki`;
const appLogPath = `${logDir}/app.log`;
const coreLogPath = `${logDir}/core.log`;
const debugLogPath = `${logDir}/debug.log`;

return baseclass.extend({
    homeDir: homeDir,
    profilesDir: profilesDir,
    subscriptionsDir: subscriptionsDir,
    mixinFilePath: mixinFilePath,
    runDir: runDir,
    runProfilePath: runProfilePath,
    ruleProvidersDir: ruleProvidersDir,
    proxyProvidersDir: proxyProvidersDir,
    appLogPath: appLogPath,
    coreLogPath: coreLogPath,
    debugLogPath: debugLogPath,

    status: async function () {
        return (await callRCList('nikki'))?.nikki?.running;
    },

    reload: function () {
        return callRCInit('nikki', 'reload');
    },

    restart: function () {
        return callRCInit('nikki', 'restart');
    },

    writefile: function (path, data, mode) {
        data = (data != null) ? String(data) : '';
        mode = (mode != null) ? Number(mode).toString(8) : '644';

        // OpenWrt 21.02 file.write has no append argument. Send bounded chunks
        // to the fixed helper instead, which validates every destination path.
        const chunkSize = 8 * 1024;
        if (data.length <= chunkSize)
            return callNikki('write-file', [path, data, '0', mode, '1']);

        let promise = Promise.resolve();
        for (let offset = 0; offset < data.length;) {
            let end = Math.min(offset + chunkSize, data.length);
            // Do not split a UTF-16 surrogate pair across two helper calls.
            if (end < data.length &&
                data.charCodeAt(end - 1) >= 0xD800 && data.charCodeAt(end - 1) <= 0xDBFF &&
                data.charCodeAt(end) >= 0xDC00 && data.charCodeAt(end) <= 0xDFFF)
                end--;
            const chunk = data.slice(offset, end);
            const append = offset > 0 ? '1' : '0';
            const final = end >= data.length ? '1' : '0';
            promise = promise.then(function () {
                return callNikki('write-file', [path, chunk, append, mode, final]);
            });
            offset = end;
        }
        return promise;
    },

    version: function () {
        return callNikki('version');
    },

    coreStatus: function () {
        return callNikki('core-status');
    },

    coreAction: function (action) {
        return callNikki('core-action', [action]);
    },

    profile: function (defaults) {
        return callNikki('profile', [JSON.stringify(defaults || {})]);
    },

    updateSubscription: function (section_id) {
        return callNikki('update-subscription', [section_id]);
    },

    updateDashboard: function () {
        return callNikki('api', ['POST', '/upgrade/ui', '', '']);
    },

    openDashboard: async function () {
        const profile = await this.profile({
            'external-ui-name': null,
            'external-controller': null,
            'external-controller-tls': null,
            'secret': null
        });
        const uiName = profile['external-ui-name'];
        const apiListen = profile['external-controller'];
        const apiTLSListen = profile['external-controller-tls'];
        const apiSecret = profile['secret'] ?? '';
        if (!apiListen && !apiTLSListen) {
            return Promise.reject('API has not been configured');
        }

        let protocol;
        let port;
        if (apiTLSListen) {
            protocol = 'https';
            port = apiTLSListen.substring(apiTLSListen.lastIndexOf(':') + 1);
        } else {
            protocol = 'http';
            port = apiListen.substring(apiListen.lastIndexOf(':') + 1);
        }

        const params = {
            host: window.location.hostname,
            hostname: window.location.hostname,
            port: port,
            secret: apiSecret
        };
        const query = new URLSearchParams(params).toString();
        let url;
        if (uiName) {
            url = `${protocol}://${window.location.hostname}:${port}/ui/${uiName}/?${query}`;
        } else {
            url = `${protocol}://${window.location.hostname}:${port}/ui/?${query}`;
        }

        setTimeout(function () { window.open(url, '_blank') }, 0);

        return Promise.resolve();
    },

    getIdentifiers: function () {
        return callNikki('identifiers');
    },

    listProfiles: function () {
        return L.resolveDefault(fs.list(this.profilesDir), []);
    },

    listRuleProviders: function () {
        return L.resolveDefault(fs.list(this.ruleProvidersDir), []);
    },

    listProxyProviders: function () {
        return L.resolveDefault(fs.list(this.proxyProvidersDir), []);
    },

    getAppLog: function () {
        return L.resolveDefault(fs.read_direct(this.appLogPath));
    },

    getCoreLog: function () {
        return L.resolveDefault(fs.read_direct(this.coreLogPath));
    },

    clearAppLog: function () {
        return this.writefile(this.appLogPath, '');
    },

    clearCoreLog: function () {
        return this.writefile(this.coreLogPath, '');
    },

    debug: function () {
        return callNikki('debug');
    },
})
