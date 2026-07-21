'use strict';
'require form';
'require view';
'require uci';
'require poll';
'require ui';
'require tools.nikki as nikki';

let coreUpdateBusy = false;
let coreUpdateLockedButtons = [];
let coreUpdatePollTimer = null;
let currentCoreInfo = {};

function renderStatus(running) {
    return updateStatus(E('input', { id: 'core_status', style: 'border: unset; font-style: italic; font-weight: bold;', readonly: '' }), running);
}

function updateStatus(element, running) {
    if (element) {
        element.style.color = running ? 'green' : 'red';
        element.value = running ? _('Running') : _('Not Running');
    }
    return element;
}

function textOrDash(value) {
    return value || '-';
}

function coreStatusText(info) {
    info = info || {};
    const labels = {
        idle: _('Not Checked'),
        source_changed: _('Update source changed, not checked!'),
        checking: _('Checking for updates, please wait.'),
        checked: _('Checked'),
        updating: _('The first update or an update without a proxy may take longer. Refresh the page every 5 minutes.'),
        success: _('Update Successful')
    };

    if ((info.status === 'error' || info.status === 'core_deleted') && info.error) {
        let errorText = info.error;
        if (info.updated_at)
            errorText += ` · ${info.updated_at}`;
        return errorText;
    }

    let text = labels[info.status] || textOrDash(info.status);
    if (info.updated_at && !['checking', 'updating', 'source_changed'].includes(info.status))
        text += ` · ${info.updated_at}`;
    return text;
}

function renderInfoValue(value, wrapAnywhere, elementId) {
    const attributes = {
        style: wrapAnywhere
            ? 'display:inline-block;max-width:100%;overflow-wrap:anywhere;word-break:break-all;'
            : 'display:inline-block;max-width:100%;overflow-wrap:anywhere;'
    };

    if (elementId)
        attributes.id = elementId;

    return E('span', attributes, [textOrDash(value)]);
}

function setCoreUpdateBusy(busy) {
    coreUpdateBusy = busy;

    if (busy) {
        coreUpdateLockedButtons = Array.prototype.map.call(
            document.querySelectorAll('.nikki-core-update-button'),
            function (button) {
                const state = { button: button, disabled: button.disabled };
                button.disabled = true;
                return state;
            }
        );
        return;
    }

    coreUpdateLockedButtons.forEach(function (state) {
        if (state.button?.isConnected)
            state.button.disabled = state.disabled;
    });
    coreUpdateLockedButtons = [];
}

function updateCoreInfoValue(root, elementId, value) {
    const element = root.querySelector(`#${elementId}`);
    if (element)
        element.textContent = textOrDash(value);
}

function updateCoreInfo(root, info) {
    info = info || {};
    currentCoreInfo = info;

    const architecture = [info.architecture_uname, info.architecture_package]
        .filter(Boolean)
        .join(' / ');

    updateCoreInfoValue(root, 'core_update_architecture', architecture);
    updateCoreInfoValue(root, 'core_update_current_version', info.current_version);
    updateCoreInfoValue(root, 'core_update_latest_version', info.latest_version);
    updateCoreInfoValue(root, 'core_update_source', info.source);
    updateCoreInfoValue(root, 'core_update_status', coreStatusText(info));
}

function scheduleReload() {
    window.setTimeout(function () { window.location.reload(); }, 250);
}

function stopCorePolling() {
    if (coreUpdatePollTimer != null) {
        window.clearTimeout(coreUpdatePollTimer);
        coreUpdatePollTimer = null;
    }
}

function pollCoreOperation(root) {
    stopCorePolling();
    coreUpdatePollTimer = window.setTimeout(function pollOnce() {
        L.resolveDefault(nikki.coreStatus(), { status: 'error' }).then(function (info) {
            updateCoreInfo(root, info);
            if (info.status === 'checking' || info.status === 'updating') {
                coreUpdatePollTimer = window.setTimeout(pollOnce, 1000);
                return;
            }
            stopCorePolling();
            scheduleReload();
        });
    }, 1000);
}

function runCheckAction(root) {
    if (coreUpdateBusy)
        return Promise.resolve();

    setCoreUpdateBusy(true);
    updateCoreInfoValue(root, 'core_update_status', _('Checking for updates, please wait.'));
    return L.resolveDefault(nikki.coreAction('check'), { success: false }).then(function () {
        scheduleReload();
    }, function () {
        scheduleReload();
    });
}

function runUpdateAction(root) {
    if (coreUpdateBusy)
        return Promise.resolve();

    setCoreUpdateBusy(true);
    updateCoreInfoValue(root, 'core_update_status', _('The first update or an update without a proxy may take longer. Refresh the page every 5 minutes.'));
    return L.resolveDefault(nikki.coreAction('update'), { success: false }).then(function (result) {
        if (!result?.success) {
            scheduleReload();
            return;
        }
        pollCoreOperation(root);
    }, function () {
        scheduleReload();
    });
}

function runDeleteCurrent(root) {
    if (coreUpdateBusy)
        return Promise.resolve();

    setCoreUpdateBusy(true);
    return L.resolveDefault(nikki.coreAction('delete-current'), { success: false }).then(function () {
        scheduleReload();
    }, function () {
        scheduleReload();
    });
}

function showDeleteCurrentDialog(root) {
    const info = currentCoreInfo || {};

    if (info.core_origin === 'firmware') {
        ui.showModal(_('Current Core'), [
            E('p', {}, [_('The current core is built into the firmware and does not occupy writable space. Deleting it cannot free space for a core update.')]),
            E('div', { class: 'right' }, [
                E('button', {
                    class: 'btn cbi-button',
                    click: ui.hideModal
                }, [_('Close')])
            ])
        ]);
        return;
    }

    if (info.core_origin === 'none') {
        ui.showModal(_('Current Core'), [
            E('p', {}, [_('There is no current core to delete.')]),
            E('div', { class: 'right' }, [
                E('button', {
                    class: 'btn cbi-button',
                    click: ui.hideModal
                }, [_('Close')])
            ])
        ]);
        return;
    }

    ui.showModal(_('Confirm Core Deletion'), [
        E('p', {}, [_('Are you sure you want to delete the current core?')]),
        E('p', {}, [_('This operation stops Nikki and deletes the downloaded core to free writable space for another core update.')]),
        E('div', { class: 'right' }, [
            E('button', {
                class: 'btn cbi-button',
                click: ui.hideModal
            }, [_('Cancel')]),
            E('button', {
                class: 'btn cbi-button-negative',
                click: function () {
                    ui.hideModal();
                    return runDeleteCurrent(root);
                }
            }, [_('Confirm Delete')])
        ])
    ]);
}

function coreActionButton(title, style, handler, elementId) {
    const attributes = {
        class: `cbi-button cbi-button-${style} nikki-core-update-button`,
        click: function (event) {
            event.preventDefault();
            return handler();
        }
    };
    if (elementId)
        attributes.id = elementId;
    return E('button', attributes, [title]);
}

return view.extend({
    load: function () {
        return Promise.all([
            uci.load('nikki'),
            nikki.version(),
            nikki.status(),
            nikki.listProfiles(),
            nikki.coreStatus()
        ]);
    },
    render: function (data) {
        const subscriptions = uci.sections('nikki', 'subscription');
        const appVersion = data[1].app ?? '';
        const coreVersion = data[1].core ?? '';
        const coreInfo = data[4] || {};
        const running = data[2];
        const profiles = data[3];

        currentCoreInfo = coreInfo;

        let m, s, o;

        m = new form.Map('nikki', _('Nikki-X'), E('div', {
            style: 'font-size:15px;line-height:1.75;'
        }, [
            E('div', {}, [_('1. This software is completely free and open source, secure and lightweight. When disabled, it uses almost no memory except for the official core.')]),
            E('div', {}, [_('2. For accurate DNS queries and routing and to prevent DNS leaks, disable encrypted DNS / secure DNS in operating systems, browsers, and other software on computers and phones.')])
        ]));

        s = m.section(form.TableSection, 'status', _('Status'));
        s.anonymous = true;

        o = s.option(form.Value, '_app_version', _('App Version'));
        o.readonly = true;
        o.load = function () { return appVersion; };
        o.write = function () { };

        o = s.option(form.Value, '_core_version', _('Core Version'));
        o.readonly = true;
        o.load = function () { return textOrDash(coreVersion); };
        o.write = function () { };

        o = s.option(form.DummyValue, '_core_status', _('Core Status'));
        o.cfgvalue = function () { return renderStatus(running); };
        poll.add(function () {
            return L.resolveDefault(nikki.status()).then(function (isRunning) {
                updateStatus(document.getElementById('core_status'), isRunning);
            });
        });

        o = s.option(form.Button, 'reload');
        o.inputstyle = 'action';
        o.inputtitle = _('Reload Service');
        o.onclick = function () { return nikki.reload(); };

        o = s.option(form.Button, 'restart');
        o.inputstyle = 'negative';
        o.inputtitle = _('Restart Service');
        o.onclick = function () { return nikki.restart(); };

        o = s.option(form.Button, 'update_dashboard');
        o.inputstyle = 'positive';
        o.inputtitle = _('Update Dashboard');
        o.onclick = function () { return nikki.updateDashboard(); };

        o = s.option(form.Button, 'open_dashboard');
        o.inputtitle = _('Open Dashboard');
        o.onclick = function () { return nikki.openDashboard(); };

        s = m.section(form.NamedSection, 'config', 'config', _('App Config'));

        o = s.option(form.Flag, 'enabled', _('Enable'));
        o.rmempty = false;

        o = s.option(form.ListValue, 'profile', _('Choose Profile'));
        o.optional = true;

        for (const profile of profiles)
            o.value('file:' + profile.name, _('File:') + profile.name);

        for (const subscription of subscriptions)
            o.value('subscription:' + subscription['.name'], _('Subscription:') + subscription.name);

        o = s.option(form.Value, 'start_delay', _('Start Delay'));
        o.datatype = 'uinteger';
        o.placeholder = _('Start Immidiately');

        o = s.option(form.Flag, 'scheduled_restart', _('Scheduled Restart'));
        o.rmempty = false;

        o = s.option(form.Value, 'scheduled_restart_cron', _('Scheduled Restart Cron'));
        o.retain = true;
        o.rmempty = false;
        o.depends('scheduled_restart', '1');

        o = s.option(form.Flag, 'test_profile', _('Test Profile'));
        o.rmempty = false;

        o = s.option(form.Flag, 'core_only', _('Core Only'));
        o.rmempty = false;

        s = m.section(form.NamedSection, 'core_update', 'core_update', _('Core Update'));
        s.description = _('After selecting an update source, be sure to click Save & Apply before checking for updates or updating the core!');

        o = s.option(form.ListValue, 'source_type', _('Update Source Selection'));
        o.default = 'official';
        o.rmempty = false;
        o.value('official', _('MetaCubeX Official Latest Version'));
        o.value('repository', _('ShellCrash Sources'));
        o.value('release', _('Custom Releases URL'));
        o.value('direct', _('Exact Direct URL'));

        o = s.option(form.ListValue, 'official_preset', _('Official Download Source'));
        o.default = 'auto';
        o.rmempty = false;
        o.depends('source_type', 'official');
        o.value('auto', _('Automatic HTTPS Fallback (Recommended)'));
        o.value('proxy', _('PROXY Acceleration (Recommended)'));
        o.value('proxynet', _('PROXYNET Acceleration'));
        o.value('github', _('GitHub Direct'));
        o.description = _('Automatic mode tries the official update sources in order. Please wait patiently.');

        o = s.option(form.ListValue, 'repository_preset', _('ShellCrash Source'));
        o.default = 'auto';
        o.rmempty = false;
        o.depends('source_type', 'repository');
        o.value('auto', _('Automatic HTTPS Fallback (Recommended)'));
        o.value('cloudflare', _('JSdelivr CF (Recommended)'));
        o.value('jsdelivr', _('jsDelivr CDN'));
        o.value('github', _('GitHub Direct'));
        o.value('author_https', _('HTTPS Mirror'));
        o.value('author_http', _('HTTP Beta Source (Unsafe)'));
        o.value('custom', _('Custom ShellCrash-Compatible Repository'));
        o.description = _('Automatic mode tries the HTTPS sources in order and stops at the first available source.');

        o = s.option(form.Value, 'repository_url', _('Custom Repository Base URL'));
        o.placeholder = 'https://example.com';
        o.depends({ source_type: 'repository', repository_preset: 'custom' });
        o.rmempty = false;

        o = s.option(form.Value, 'releases_url', _('Releases URL'));
        o.default = 'https://github.com/MetaCubeX/mihomo/releases';
        o.placeholder = 'https://example.com/releases';
        o.depends('source_type', 'release');
        o.rmempty = false;

        o = s.option(form.Value, 'releases_tag', _('Release Tag'));
        o.default = 'latest';
        o.placeholder = 'latest / v1.19.29';
        o.depends('source_type', 'release');
        o.rmempty = false;

        o = s.option(form.Value, 'direct_url', _('Exact Direct URL'));
        o.placeholder = 'https://example.com/mihomo-linux-arm64-v1.19.29.gz';
        o.depends('source_type', 'direct');
        o.rmempty = false;

        o = s.option(form.DummyValue, '_device_architecture', _('Device Architecture'));
        o.cfgvalue = function () { return renderInfoValue(coreInfo.architecture_uname && coreInfo.architecture_package ? `${coreInfo.architecture_uname} / ${coreInfo.architecture_package}` : null, false, 'core_update_architecture'); };

        o = s.option(form.DummyValue, '_current_version', _('Current Version'));
        o.cfgvalue = function () { return renderInfoValue(coreInfo.current_version, false, 'core_update_current_version'); };

        o = s.option(form.DummyValue, '_update_version', _('Update Version'));
        o.cfgvalue = function () { return renderInfoValue(coreInfo.latest_version, false, 'core_update_latest_version'); };

        o = s.option(form.DummyValue, '_update_source', _('Update Source'));
        o.cfgvalue = function () { return renderInfoValue(coreInfo.source, true, 'core_update_source'); };

        o = s.option(form.DummyValue, '_update_status', _('Update Status'));
        o.cfgvalue = function () { return renderInfoValue(coreStatusText(coreInfo), true, 'core_update_status'); };

        o = s.option(form.DummyValue, '_check_update', _('Check Update'));
        o.description = _('Be sure to click Save & Apply at the bottom right first!');
        o.cfgvalue = function () {
            return coreActionButton(_('Check Update'), 'action', function () { return runCheckAction(document); }, 'core_update_check_button');
        };

        o = s.option(form.DummyValue, '_update_core', _('Update Core'));
        o.description = _('Be sure to click Save & Apply at the bottom right first!');
        o.cfgvalue = function () {
            return coreActionButton(_('Update Core'), 'positive', function () { return runUpdateAction(document); }, 'core_update_update_button');
        };

        o = s.option(form.DummyValue, '_delete_current_core', _('Force Delete Current Core'));
        o.description = _('If you have tried everything and truly cannot free enough space to update the core, delete the current core and try again.');
        o.cfgvalue = function () {
            return coreActionButton(_('Force Delete Current Core'), 'negative', function () { return showDeleteCurrentDialog(document); }, 'core_update_delete_button');
        };

        s = m.section(form.NamedSection, 'procd', 'procd', _('procd Config'));

        s.tab('general', _('General Config'));

        o = s.taboption('general', form.Flag, 'fast_reload', _('Fast Reload'));
        o.rmempty = false;

        s.tab('rlimit', _('RLIMIT Config'));

        o = s.taboption('rlimit', form.Value, 'rlimit_nproc_soft', _('Number of Processes Soft Limit'));
        o.datatype = 'uinteger';

        o = s.taboption('rlimit', form.Value, 'rlimit_nproc_hard', _('Number of Processes Hard Limit'));
        o.datatype = 'uinteger';

        o = s.taboption('rlimit', form.Value, 'rlimit_address_space_soft', _('Address Space Size Soft Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_address_space_hard', _('Address Space Size Hard Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_data_soft', _('Heap Size Soft Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_data_hard', _('Heap Size Hard Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_stack_soft', _('Stack Size Soft Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_stack_hard', _('Stack Size Hard Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_nofile_soft', _('Number of Open Files Soft Limit'));
        o.datatype = 'uinteger';

        o = s.taboption('rlimit', form.Value, 'rlimit_nofile_hard', _('Number of Open Files Hard Limit'));
        o.datatype = 'uinteger';

        s.tab('environment_variable', _('Environment Variable Config'));

        o = s.taboption('environment_variable', form.Value, 'env_go_max_procs', 'GOMAXPROCS');
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('environment_variable', form.Value, 'env_go_mem_limit', 'GOMEMLIMIT');
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('environment_variable', form.DynamicList, 'env_safe_paths', _('Safe Paths'));
        o.load = function (section_id) {
            return this.super('load', section_id)?.split(':');
        };
        o.write = function (section_id, formvalue) {
            this.super('write', section_id, formvalue?.join(':'));
        };

        o = s.taboption('environment_variable', form.Flag, 'env_disable_loopback_detector', _('Disable Loopback Detector'));
        o.rmempty = false;

        o = s.taboption('environment_variable', form.Flag, 'env_disable_quic_go_gso', _('Disable GSO of quic-go'));
        o.rmempty = false;

        o = s.taboption('environment_variable', form.Flag, 'env_disable_quic_go_ecn', _('Disable ECN of quic-go'));
        o.rmempty = false;

        o = s.taboption('environment_variable', form.Flag, 'env_skip_system_ipv6_check', _('Skip System IPv6 Check'));
        o.rmempty = false;

        return m.render().then(function (root) {
            updateCoreInfo(root, coreInfo);
            if (coreInfo.status === 'checking' || coreInfo.status === 'updating') {
                window.setTimeout(function () {
                    setCoreUpdateBusy(true);
                    pollCoreOperation(document);
                }, 0);
            }
            return root;
        });
    }
});
