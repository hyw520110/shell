#!/usr/bin/env node
/**
 * Typora macOS 激活脚本
 * 原理：替换二进制中的 RSA 公钥，用自己的私钥签名生成 Activation Token
 */

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
let readlineSync = null; try { readlineSync = require('readline-sync'); } catch (e) { /* 非交互无需 */ }
const os = require('os');

// ================================
// 配置
// ================================
const CONFIG_FILE = path.join(os.homedir(), '.typora_crack_config.json');
const DEFAULT_APP_PATH = '/Applications/Typora.app';
const ORIGINAL_PUB_KEY = `-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA7nVoGCHqIMJyqgALEUrc
5JJhap0+HtJqzPE04pz4y+nrOmY7/12f3HvZyyoRsxKdXTZbO0wEHFIh0cRqsuaJ
PyaOOPbA0BsalofIAY3mRhQQ3vSf+rn3g+w0S+udWmKV9DnmJlpWqizFajU4T/E4
5ZgMNcXt3E1ips32rdbTR0Nnen9PVITvrbJ3l6CI2BFBImZQZ2P8N+LsqfJsqyVV
wDkt3mHAVxV7FZbfYWG+8FDSuKQHaCmvgAtChx9hwl3J6RekkqDVa6GIV13D23LS
qdk0Jb521wFJi/V6QAK6SLBiby5gYN6zQQ5RQpjXtR53MwzTdiAzGEuKdOtrY2Me
DwIDAQAB
-----END PUBLIC KEY-----`;

// ================================
// 工具函数
// ================================
function getBinaryPath(appPath) {
    return path.join(appPath, 'Contents', 'MacOS', 'Typora');
}

function readCache() {
    try {
        if (fs.existsSync(CONFIG_FILE)) {
            const data = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
            if (data.path && fs.existsSync(getBinaryPath(data.path))) {
                return data;
            }
        }
    } catch (e) {}
    return { path: null, machineCode: null, email: null };
}

function saveCache(obj) {
    try { fs.writeFileSync(CONFIG_FILE, JSON.stringify(obj, null, 2), 'utf8'); } catch (e) {}
}

function getNowDateStr() {
    const now = new Date();
    const dd = String(now.getDate()).padStart(2, '0');
    const mm = String(now.getMonth() + 1).padStart(2, '0');
    return `${mm}/${dd}/${now.getFullYear()}`;
}

// ================================
// 选择 Typora 路径
// ================================
function chooseTyporaPath() {
    // 非交互：直接使用默认路径
    if (fs.existsSync(getBinaryPath(DEFAULT_APP_PATH))) {
        return DEFAULT_APP_PATH;
    }
    const cache = readCache();

    if (cache.path) {
        console.log(`\n✅ 检测到缓存路径: ${cache.path}`);
        const use = readlineSync.question('是否使用此路径？[Y/n]：').trim().toLowerCase();
        if (use !== 'n' && use !== 'no') return cache.path;
    }

    if (fs.existsSync(getBinaryPath(DEFAULT_APP_PATH))) {
        console.log(`\n✅ 检测到默认路径: ${DEFAULT_APP_PATH}`);
        const use = readlineSync.question('是否使用此路径？[Y/n]：').trim().toLowerCase();
        if (use !== 'n' && use !== 'no') {
            saveCache({ ...cache, path: DEFAULT_APP_PATH });
            return DEFAULT_APP_PATH;
        }
    }

    try {
        const output = spawnSync('osascript', ['-e',
            'POSIX path of (choose folder with prompt "请选择 Typora.app 所在目录")'
        ], { encoding: 'utf8' }).stdout.trim();
        if (output) {
            let p = path.resolve(output.replace(/\/$/, ''));
            if (!p.endsWith('.app')) p = path.join(p, 'Typora.app');
            if (fs.existsSync(getBinaryPath(p))) {
                saveCache({ ...cache, path: p });
                return p;
            }
        }
    } catch (e) {}

    while (true) {
        const input = readlineSync.question('请输入 Typora.app 路径：').trim();
        if (!input) continue;
        const p = path.resolve(input);
        if (fs.existsSync(getBinaryPath(p))) {
            saveCache({ ...cache, path: p });
            return p;
        }
        console.log('❌ 路径无效，未找到 Typora 二进制');
    }
}

// ================================
// 获取机器码和邮箱
// ================================
function getMachineCodeAndEmail() {
    const cache = readCache();
    // 非交互：优先命令行参数
    const cliMachineCode = process.env.TYPORA_MACHINE_CODE || '';
    const cliEmail = process.env.TYPORA_EMAIL || '';
    if (cliMachineCode && cliEmail) {
        console.log(`\n✅ 使用命令行提供的机器码/邮箱`);
        return { machineCode: cliMachineCode, email: cliEmail };
    }
    if (cache.machineCode && cache.email) {
        console.log(`\n✅ 使用缓存的激活信息`);
        return { machineCode: cache.machineCode, email: cache.email };
    }
    throw new Error('缺少机器码/邮箱。请设置环境变量 TYPORA_MACHINE_CODE 和 TYPORA_EMAIL，或先运行交互版');
}

// ================================
// 回滚还原
// ================================
function rollback(appPath) {
    console.log('\n🔄 开始回滚还原...');
    const binPath = getBinaryPath(appPath);
    const bakPath = binPath + '.bak';

    spawnSync('killall', ['Typora'], { stdio: 'ignore' });

    if (fs.existsSync(bakPath)) {
        fs.copyFileSync(bakPath, binPath);
        fs.rmSync(bakPath, { force: true });
        console.log('✅ 已还原 Typora 二进制');
    } else {
        console.log('⚠️  未找到备份文件，无需回滚');
        return;
    }

    spawnSync('defaults', ['delete', 'abnerworks.Typora', 'typora-license'], { stdio: 'ignore' });
    spawnSync('codesign', ['--force', '--deep', '-s', '-', appPath], { stdio: 'ignore' });
    console.log('✅ 已清理授权信息并重新签名');
    console.log('\n🎉 回滚完成！');
}

// ================================
// 主流程
// ================================
(function main() {
    process.stdout.write('\x1Bc');
    console.log('=================================');
    console.log('    Typora macOS 激活脚本');
    console.log('=================================');

    const appPath = chooseTyporaPath();
    const binPath = getBinaryPath(appPath);
    const bakPath = binPath + '.bak';

    if (fs.existsSync(bakPath)) {
        if (process.env.TYPORA_ROLLBACK === '1') { rollback(appPath); process.exit(0); }
        console.log('\n⚠️  检测到已激活过，重新 Patch');
        console.log('还原原始二进制...');
        fs.copyFileSync(bakPath, binPath);
        fs.rmSync(bakPath, { force: true });
        spawnSync('defaults', ['delete', 'abnerworks.Typora', 'typora-license'], { stdio: 'ignore' });
    }

    const { machineCode, email } = getMachineCodeAndEmail();
    const mc = JSON.parse(Buffer.from(machineCode, 'base64').toString('utf8'));
    console.log(`\ndeviceId: ${mc.l}`);
    console.log(`fingerprint: ${mc.i}`);
    console.log(`version: ${mc.v}`);

    spawnSync('killall', ['Typora'], { stdio: 'ignore' });

    const nowDateStr = getNowDateStr();

    // 一、生成密钥对
    console.log('\n一、生成密钥对...');
    const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
        modulusLength: 2048,
        publicKeyEncoding: { type: 'spki', format: 'pem' },
        privateKeyEncoding: { type: 'pkcs8', format: 'pem' }
    });

    const pubKeyBase64 = publicKey
        .replace('-----BEGIN PUBLIC KEY-----', '')
        .replace('-----END PUBLIC KEY-----', '')
        .replace(/\s/g, '');
    const lines = [];
    for (let i = 0; i < pubKeyBase64.length; i += 64) {
        lines.push(pubKeyBase64.slice(i, i + 64));
    }
    const formattedPubKey = '-----BEGIN PUBLIC KEY-----\n' + lines.join('\n') + '\n-----END PUBLIC KEY-----';
    const newKeyBuf = Buffer.from(formattedPubKey, 'utf8');
    const originalKeyBuf = Buffer.from(ORIGINAL_PUB_KEY, 'utf8');

    if (newKeyBuf.length !== originalKeyBuf.length) {
        console.log(`❌ 公钥长度不匹配: 期望 ${originalKeyBuf.length}, 实际 ${newKeyBuf.length}`);
        process.exit(1);
    }
    console.log(`✅ 密钥对生成成功 (${newKeyBuf.length} 字节)`);

    // 二、Patch 二进制
    console.log('\n二、Patch 二进制...');
    fs.copyFileSync(binPath, bakPath);

    let binaryData = fs.readFileSync(binPath);
    let offset = 0, replacements = 0;
    while (true) {
        const idx = binaryData.indexOf(originalKeyBuf, offset);
        if (idx === -1) break;
        newKeyBuf.copy(binaryData, idx);
        offset = idx + newKeyBuf.length;
        replacements++;
    }

    if (replacements === 0) {
        console.log('❌ 未在二进制中找到原始公钥，可能版本不兼容');
        fs.copyFileSync(bakPath, binPath);
        fs.rmSync(bakPath, { force: true });
        process.exit(1);
    }

    fs.writeFileSync(binPath, binaryData);
    console.log(`✅ 已替换 ${replacements} 处公钥`);

    // 三、生成 Activation Token
    console.log('\n三、生成 Activation Token...');

    const ACT_ENTITY = {
        deviceId: mc.l,
        fingerprint: mc.i,
        email: email,
        license: "Cracked_By_DreamNya&Letr",
        version: mc.v,
        date: nowDateStr,
        type: "DreamNya"
    };

    const licenseJSON = JSON.stringify(ACT_ENTITY);
    const jsonBase64 = Buffer.from(licenseJSON, 'utf8').toString('base64');

    // 模拟浏览器 atob：UTF-8 bytes → Latin1 string
    const atobResult = Buffer.from(jsonBase64, 'base64').toString('latin1');
    const parsedAfterAtob = JSON.parse(atobResult);

    // 按 key 字母排序，跳过 sig/oldSig/oldFinger，拼接值
    const skipKeys = new Set(['sig', 'oldSig', 'oldFinger']);
    const sortedKeys = Object.keys(parsedAfterAtob).filter(k => !skipKeys.has(k)).sort();
    const dataToSign = sortedKeys.map(k => String(parsedAfterAtob[k])).join('');

    // SHA256 + PKCS1v15 签名
    const signature = crypto.sign('SHA256', Buffer.from(dataToSign, 'utf8'), {
        key: privateKey,
        padding: crypto.constants.RSA_PKCS1_PADDING
    });

    const activationToken = '+' + jsonBase64 + '|' + signature.toString('base64') + '#';
    console.log('✅ Token 生成成功');

    // 四、重新签名
    console.log('\n四、重新签名应用...');
    const signResult = spawnSync('codesign', ['--force', '--deep', '-s', '-', appPath], {
        encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']
    });
    if (signResult.status !== 0) {
        console.log(`⚠️  签名警告: ${(signResult.stderr || '').trim()}`);
    } else {
        console.log('✅ 应用重新签名成功');
    }

    // 完成
    console.log('\n🎉 全部完成！');
    console.log('\n使用方法：');
    console.log('1. 打开 Typora → 帮助 → 我的许可证');
    console.log('2. 点击「获取 Activation Token」进入离线激活页面');
    console.log('3. 在 Activation Token 框中粘贴以下内容：\n');
    console.log(activationToken);
    console.log('\n（Token 已复制到剪贴板）');

    try { spawnSync('pbcopy', [], { input: activationToken, encoding: 'utf8' }); } catch (e) {}
})();