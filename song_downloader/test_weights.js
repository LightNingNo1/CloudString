// test_weights.js - 模拟 tfjs decodeWeights 的解析逻辑，定位权重错位
const fs = require('fs');
const path = require('path');

const modelDir = path.join(__dirname, 'node_modules', '@spotify', 'basic-pitch', 'model');
const modelJson = JSON.parse(fs.readFileSync(path.join(modelDir, 'model.json'), 'utf8'));
const manifest = modelJson.weightsManifest[0];
const buf = new Uint8Array(fs.readFileSync(path.join(modelDir, manifest.paths[0])));

const FACTOR = { 'float32': 4, 'int32': 4, 'bool': 1 };
function sizeFromShape(shape) {
    let s = 1;
    for (const d of shape) s *= d;
    return s;
}

let offset = 0;
let bad = 0;
for (let i = 0; i < manifest.weights.length; i++) {
    const spec = manifest.weights[i];
    const size = sizeFromShape(spec.shape);
    const factor = FACTOR[spec.dtype];
    const byteBuffer = buf.slice(offset, offset + size * factor);
    offset += size * factor;
    let nvals = 0;
    if (spec.dtype === 'int32') nvals = new Int32Array(byteBuffer).length;
    else if (spec.dtype === 'float32') nvals = new Float32Array(byteBuffer).length;
    if (nvals !== size) {
        bad++;
        if (bad <= 5) {
            console.log(`[bad] idx=${i} ${spec.name} dtype=${spec.dtype} shape=[${spec.shape}] size=${size} factor=${factor} bytes=${byteBuffer.length} vals=${nvals}`);
        }
    }
}
console.log('总权重:', manifest.weights.length, '不匹配:', bad, 'offset 结束:', offset, '/ bin:', buf.length);
