import { LightningElement } from 'lwc';
import getGameData from '@salesforce/apex/SupplyChainTDController.getGameData';

// ── Constants ──
const W = 960, H = 680;
const MAX_WAVES = 10;
const FACTORY_MAX_HP = 100;

// Tower definitions
const TOWERS = [
    { id: 'barrier', name: '防災拠点', cost: 80, icon: '🏗', color: '#4af', range: 90, damage: 8, rate: 60, desc: '基本防衛。射程が広い' },
    { id: 'buffer', name: '在庫バッファ', cost: 120, icon: '📦', color: '#fa0', range: 70, damage: 3, rate: 40, desc: '敵を50%減速させる', slow: 0.5 },
    { id: 'team', name: '緊急対応', cost: 180, icon: '🚒', color: '#f44', range: 55, damage: 22, rate: 80, desc: '高火力・短射程' },
    { id: 'scm', name: 'SCM司令塔', cost: 280, icon: '📡', color: '#0f0', range: 100, damage: 5, rate: 50, desc: '範囲内タワー+30%強化', boost: 1.3 }
];

// Enemy definitions per wave
const ENEMY_TYPES = {
    quake:    { name: '地震', color: '#f84', hp: 80, speed: 0.7, reward: 15, size: 10 },
    tsunami:  { name: '津波', color: '#4cf', hp: 50, speed: 1.8, reward: 12, size: 8 },
    typhoon:  { name: '台風', color: '#c6f', hp: 140, speed: 1.0, reward: 25, size: 12 },
    pandemic: { name: 'パンデミック', color: '#af0', hp: 300, speed: 0.4, reward: 45, size: 16 },
    megaquake:{ name: '巨大地震', color: '#f22', hp: 600, speed: 0.5, reward: 100, size: 22 }
};

// Wave configs
const WAVES = [
    { enemies: [{ type: 'quake', count: 6 }], origin: 'south', label: '地震 - 南海沖' },
    { enemies: [{ type: 'quake', count: 8 }, { type: 'tsunami', count: 3 }], origin: 'south', label: '地震+津波 - 南海沖' },
    { enemies: [{ type: 'typhoon', count: 5 }], origin: 'west', label: '台風 - 西方沖' },
    { enemies: [{ type: 'quake', count: 10 }, { type: 'tsunami', count: 5 }], origin: 'east', label: '地震+津波 - 関東沖' },
    { enemies: [{ type: 'typhoon', count: 6 }, { type: 'quake', count: 6 }], origin: 'south', label: '複合災害 - 太平洋沖' },
    { enemies: [{ type: 'pandemic', count: 3 }], origin: 'all', label: 'パンデミック - 全方位' },
    { enemies: [{ type: 'quake', count: 12 }, { type: 'typhoon', count: 6 }, { type: 'tsunami', count: 6 }], origin: 'east', label: '首都直下型地震' },
    { enemies: [{ type: 'pandemic', count: 4 }, { type: 'typhoon', count: 8 }], origin: 'west', label: 'パンデミック+台風' },
    { enemies: [{ type: 'quake', count: 15 }, { type: 'tsunami', count: 8 }, { type: 'typhoon', count: 5 }], origin: 'south', label: '南海トラフ巨大地震' },
    { enemies: [{ type: 'megaquake', count: 2 }, { type: 'quake', count: 10 }, { type: 'tsunami', count: 8 }, { type: 'typhoon', count: 6 }], origin: 'all', label: '超巨大複合災害' }
];

// Japan map outline — geo coords [lat, lng] converted at render time
const HOKKAIDO_GEO = [
    [41.8,140.7],[42.0,140.2],[42.3,140.4],[42.5,140.2],[42.8,140.0],
    [43.1,140.3],[43.3,140.2],[43.4,140.5],[43.8,141.0],[44.3,141.7],
    [45.0,141.7],[45.4,141.9],[45.5,142.1],[45.3,142.5],[44.9,143.2],
    [44.4,143.4],[44.1,144.3],[43.5,145.3],[43.3,145.6],[43.1,145.1],
    [43.0,144.4],[42.9,143.8],[42.3,143.3],[42.0,143.0],[42.0,142.5],
    [41.8,141.5],[41.8,140.7]
];
const HONSHU_GEO = [
    // Pacific coast: Shimonoseki → northeast
    [33.9,130.9],[34.0,131.5],[34.1,132.1],[34.2,132.5],[34.3,133.0],
    [34.3,133.6],[34.2,134.2],[34.5,135.0],[34.6,135.4],
    // Kii Peninsula
    [34.3,135.2],[34.0,135.3],[33.7,135.6],[33.5,135.8],[33.4,136.0],
    [33.9,136.5],[34.3,136.8],[34.6,137.0],
    // Shizuoka → Tokyo
    [34.6,137.7],[34.6,138.2],[34.8,138.6],[34.9,138.9],
    [34.7,139.1],[34.9,139.3],[35.1,139.7],[35.3,139.9],[35.7,140.0],
    // Choshi → Tohoku coast
    [35.7,140.9],[36.3,140.7],[36.8,140.9],[37.3,141.0],
    [37.8,141.0],[38.3,141.1],[38.8,141.7],[39.3,142.0],
    [39.8,142.1],[40.2,142.0],[40.5,141.7],[40.9,141.5],
    [41.0,141.2],[41.3,141.2],[41.5,141.0],
    // Shimokita Peninsula
    [41.4,140.9],[41.3,140.7],[41.0,140.5],
    // Sea of Japan coast: Aomori → southwest
    [40.8,140.0],[40.5,139.9],[40.0,139.8],[39.8,140.0],[39.7,139.9],
    [39.2,139.8],[38.8,139.5],[38.3,139.2],[37.9,139.0],
    // Niigata → Noto
    [37.5,138.5],[37.1,137.8],[37.2,137.2],[37.4,136.9],
    [37.5,136.7],[37.3,136.7],[37.1,136.8],[36.8,136.6],
    [36.5,136.3],[36.2,136.0],[36.0,135.8],[35.8,135.5],
    // San'in coast
    [35.6,134.6],[35.5,134.2],[35.5,133.5],[35.5,132.8],
    [35.4,132.3],[34.6,131.7],[34.3,131.3],[33.9,130.9]
];
const SHIKOKU_GEO = [
    [33.9,132.7],[34.1,132.5],[34.2,133.0],[34.3,133.5],[34.4,134.0],
    [34.3,134.5],[34.1,134.6],[33.7,134.3],[33.3,133.8],[33.0,133.3],
    [32.8,133.0],[33.0,132.7],[33.3,132.5],[33.6,132.5],[33.9,132.7]
];
const KYUSHU_GEO = [
    [33.9,131.0],[33.6,130.5],[33.3,130.2],[33.0,129.8],[32.7,129.7],
    [32.4,129.8],[32.1,130.0],[31.8,130.3],[31.4,130.7],[31.2,131.0],
    [31.4,131.3],[31.8,131.5],[32.2,131.7],[32.6,131.8],[33.0,131.7],
    [33.3,131.6],[33.6,131.2],[33.9,131.0]
];

// Spawn origins
const ORIGINS = {
    south: [{ x: 350, y: H + 20 }, { x: 450, y: H + 20 }],
    east:  [{ x: W + 20, y: 280 }, { x: W + 20, y: 350 }],
    west:  [{ x: -20, y: 400 }, { x: -20, y: 460 }],
    all:   [{ x: -20, y: 300 }, { x: W + 20, y: 300 }, { x: 350, y: H + 20 }, { x: W + 20, y: 450 }]
};

export default class SupplyChainTD extends LightningElement {
    // UI state
    showTitle = true;
    showHud = false;
    showResult = false;
    resultTitle = '';
    resultDetail = '';
    score = 0;

    // Game state
    phase = 'title'; // title, planning, wave, gameover, victory
    money = 0;
    wave = 0;
    factories = [];
    towers = [];
    enemies = [];
    projectiles = [];
    particles = [];
    selectedTowerId = null;
    hoverCell = null;
    spawnQueue = [];
    spawnTimer = 0;
    waveAnnounceTick = 0;
    waveAnnounceText = '';
    animFrame = null;
    canvas = null;
    ctx = null;
    supplierSites = [];
    tick = 0;
    comboCount = 0;
    comboTimer = 0;
    shakeX = 0;
    shakeY = 0;

    // Reactive getters
    get currentWave() { return this.wave; }
    get maxWaves() { return MAX_WAVES; }
    get nextWave() { return this.wave + 1; }
    get displayMoney() { return this.money.toLocaleString(); }
    get isPlanning() { return this.phase === 'planning'; }
    get startWaveLabel() { return 'WAVE ' + (this.wave + 1) + ' START'; }

    get towerTypes() {
        return TOWERS.map(t => ({
            id: t.id,
            name: t.name,
            cost: t.cost,
            icon: t.icon,
            desc: t.desc,
            costLabel: '$' + t.cost,
            cssClass: 'tw-card' +
                (this.selectedTowerId === t.id ? ' tw-card-selected' : '') +
                (this.money < t.cost ? ' tw-card-disabled' : ''),
            iconStyle: 'background:' + t.color + '33;'
        }));
    }

    get factoryHpList() {
        return this.factories.map((f, idx) => {
            const pct = Math.max(0, f.hp / FACTORY_MAX_HP * 100);
            const clr = pct > 60 ? '#0f0' : pct > 30 ? '#fa0' : '#f22';
            return {
                key: 'f' + idx,
                name: f.shortName,
                hp: Math.ceil(f.hp),
                barStyle: 'width:' + pct + '%;background:' + clr + ';'
            };
        });
    }

    // ── Lifecycle ──
    renderedCallback() {
        if (this.canvas) return;
        const c = this.template.querySelector('[data-id="gameCanvas"]');
        if (!c) return;
        this.canvas = c;
        this.ctx = c.getContext('2d');
        this.resizeCanvas();
        this.renderTitle();
        this.loadGameData();
    }

    resizeCanvas() {
        const rect = this.canvas.parentElement.getBoundingClientRect();
        this.canvas.width = W;
        this.canvas.height = H;
    }

    async loadGameData() {
        try {
            const data = await getGameData();
            if (data.ownSites) {
                this.sfOwnSites = data.ownSites;
                this.sfSupplierSites = data.supplierSites || [];
            }
        } catch (e) {
            // Use fallback data
            this.sfOwnSites = null;
        }
    }

    // ── Map coord conversion (lat/lng → canvas) ──
    geoToCanvas(lat, lng) {
        const x = 100 + (lng - 129) / 17 * 760;
        const y = 580 - (lat - 31) / 14 * 520;
        return { x, y };
    }

    // ── Game Init ──
    initGame() {
        // Factories from real data or fallback
        const defaultFactories = [
            { name: '浜松工場', shortName: '浜松', lat: 34.71, lng: 137.73 },
            { name: '名古屋工場', shortName: '名古屋', lat: 35.18, lng: 136.91 },
            { name: '仙台工場', shortName: '仙台', lat: 38.27, lng: 140.87 },
            { name: '京都工場', shortName: '京都', lat: 35.01, lng: 135.77 }
        ];

        let factoryData = defaultFactories;
        if (this.sfOwnSites && this.sfOwnSites.length > 0) {
            factoryData = this.sfOwnSites.map(s => ({
                name: s.name,
                shortName: s.name.replace(/(工場|拠点|事業所)/, ''),
                lat: s.lat,
                lng: s.lng
            }));
        }

        this.factories = factoryData.map(f => {
            const pos = this.geoToCanvas(f.lat, f.lng);
            return { ...f, x: pos.x, y: pos.y, hp: FACTORY_MAX_HP, maxHp: FACTORY_MAX_HP };
        });

        // Supplier sites
        this.supplierSites = [];
        if (this.sfSupplierSites && this.sfSupplierSites.length > 0) {
            this.supplierSites = this.sfSupplierSites.map(s => {
                const pos = this.geoToCanvas(s.lat, s.lng);
                return { ...s, x: pos.x, y: pos.y };
            });
        }

        this.towers = [];
        this.enemies = [];
        this.projectiles = [];
        this.particles = [];
        this.money = 400;
        this.score = 0;
        this.wave = 0;
        this.tick = 0;
        this.comboCount = 0;
        this.comboTimer = 0;
        this.selectedTowerId = null;
        this.phase = 'planning';
        this.showTitle = false;
        this.showResult = false;
        this.showHud = true;
    }

    // ── Main Game Loop ──
    gameLoop() {
        if (this.phase === 'title') return;
        this.tick++;
        this.update();
        this.renderGame();
        this.animFrame = requestAnimationFrame(() => this.gameLoop());
    }

    stopLoop() {
        if (this.animFrame) {
            cancelAnimationFrame(this.animFrame);
            this.animFrame = null;
        }
    }

    // ── Update ──
    update() {
        if (this.phase === 'gameover' || this.phase === 'victory') return;

        // Wave announcement
        if (this.waveAnnounceTick > 0) {
            this.waveAnnounceTick--;
        }

        // Shake decay
        this.shakeX *= 0.9;
        this.shakeY *= 0.9;

        // Combo timer
        if (this.comboTimer > 0) {
            this.comboTimer--;
            if (this.comboTimer <= 0) this.comboCount = 0;
        }

        // Spawn enemies
        if (this.phase === 'wave' && this.spawnQueue.length > 0) {
            this.spawnTimer--;
            if (this.spawnTimer <= 0) {
                const e = this.spawnQueue.shift();
                this.enemies.push(e);
                this.spawnTimer = 30 + Math.random() * 20;
            }
        }

        // Check wave end
        if (this.phase === 'wave' && this.spawnQueue.length === 0 && this.enemies.length === 0) {
            if (this.wave >= MAX_WAVES) {
                this.victory();
            } else {
                this.phase = 'planning';
                this.money += 50 + this.wave * 10; // Wave bonus
            }
        }

        // Update enemies
        for (let i = this.enemies.length - 1; i >= 0; i--) {
            const e = this.enemies[i];
            // Find nearest factory
            let nearF = null, nearD = Infinity;
            for (const f of this.factories) {
                if (f.hp <= 0) continue;
                const d = Math.hypot(f.x - e.x, f.y - e.y);
                if (d < nearD) { nearD = d; nearF = f; }
            }
            if (!nearF) continue;

            // Move toward factory
            const speed = e.speed * (e.slowTimer > 0 ? e.slowMult : 1);
            if (e.slowTimer > 0) e.slowTimer--;
            const dx = nearF.x - e.x, dy = nearF.y - e.y;
            const dist = Math.hypot(dx, dy);
            if (dist > 0) {
                e.x += (dx / dist) * speed;
                e.y += (dy / dist) * speed;
                e.angle = Math.atan2(dy, dx);
            }

            // Hit factory
            if (dist < 20) {
                nearF.hp -= 10 + this.wave * 2;
                this.shakeX = (Math.random() - 0.5) * 10;
                this.shakeY = (Math.random() - 0.5) * 10;
                this.spawnExplosion(e.x, e.y, '#f44', 8);
                this.enemies.splice(i, 1);
                // Check game over
                if (this.factories.every(f => f.hp <= 0)) {
                    this.gameOver();
                }
                continue;
            }

            // Remove dead enemies
            if (e.hp <= 0) {
                this.score += e.reward * (1 + Math.floor(this.comboCount / 5) * 0.5);
                this.money += e.reward;
                this.comboCount++;
                this.comboTimer = 90;
                this.spawnExplosion(e.x, e.y, e.color, 15);
                this.enemies.splice(i, 1);
            }
        }

        // Update towers
        for (const t of this.towers) {
            t.cooldown--;
            if (t.cooldown > 0) continue;

            // Check boost from SCM towers
            let dmgMult = 1;
            if (t.def.id !== 'scm') {
                for (const st of this.towers) {
                    if (st.def.id === 'scm' && st !== t) {
                        const d = Math.hypot(st.x - t.x, st.y - t.y);
                        if (d < st.def.range) dmgMult = st.def.boost;
                    }
                }
            }

            // Find target
            let target = null, targetDist = Infinity;
            for (const e of this.enemies) {
                const d = Math.hypot(e.x - t.x, e.y - t.y);
                if (d < t.def.range && d < targetDist) {
                    target = e;
                    targetDist = d;
                }
            }

            if (target) {
                t.cooldown = t.def.rate;
                t.targetAngle = Math.atan2(target.y - t.y, target.x - t.x);
                this.projectiles.push({
                    x: t.x, y: t.y,
                    tx: target.x, ty: target.y,
                    target,
                    damage: t.def.damage * dmgMult,
                    speed: 4,
                    color: t.def.color,
                    slow: t.def.slow || 0,
                    trail: []
                });
            }
        }

        // Update projectiles
        for (let i = this.projectiles.length - 1; i >= 0; i--) {
            const p = this.projectiles[i];
            p.trail.push({ x: p.x, y: p.y });
            if (p.trail.length > 6) p.trail.shift();

            const dx = p.target.x - p.x, dy = p.target.y - p.y;
            const dist = Math.hypot(dx, dy);
            if (dist < 8 || dist > 500) {
                // Hit
                p.target.hp -= p.damage;
                if (p.slow > 0) {
                    p.target.slowTimer = 120;
                    p.target.slowMult = p.slow;
                }
                this.spawnExplosion(p.x, p.y, p.color, 4);
                this.projectiles.splice(i, 1);
                continue;
            }
            p.x += (dx / dist) * p.speed;
            p.y += (dy / dist) * p.speed;
        }

        // Update particles
        for (let i = this.particles.length - 1; i >= 0; i--) {
            const p = this.particles[i];
            p.x += p.vx;
            p.y += p.vy;
            p.vy += 0.05;
            p.life--;
            if (p.life <= 0) this.particles.splice(i, 1);
        }
    }

    // ── Render ──
    renderGame() {
        const ctx = this.ctx;
        if (!ctx) return;

        ctx.save();
        ctx.translate(this.shakeX, this.shakeY);

        // Background
        ctx.fillStyle = '#070720';
        ctx.fillRect(-10, -10, W + 20, H + 20);

        // Grid dots
        ctx.fillStyle = '#1a1a3a';
        for (let x = 0; x < W; x += 32) {
            for (let y = 0; y < H; y += 32) {
                ctx.fillRect(x, y, 1, 1);
            }
        }

        // Draw Japan map
        this.drawMapOutline(ctx);

        // Draw supplier sites
        for (const s of this.supplierSites) {
            ctx.fillStyle = 'rgba(100,200,255,0.15)';
            ctx.beginPath();
            ctx.arc(s.x, s.y, 8, 0, Math.PI * 2);
            ctx.fill();
            ctx.fillStyle = '#4ac';
            ctx.beginPath();
            ctx.arc(s.x, s.y, 3, 0, Math.PI * 2);
            ctx.fill();
        }

        // Draw tower ranges (for selected/hover)
        if (this.selectedTowerId && this.hoverCell) {
            const def = TOWERS.find(t => t.id === this.selectedTowerId);
            if (def) {
                ctx.strokeStyle = `${def.color}44`;
                ctx.fillStyle = `${def.color}11`;
                ctx.beginPath();
                ctx.arc(this.hoverCell.x, this.hoverCell.y, def.range, 0, Math.PI * 2);
                ctx.fill();
                ctx.stroke();
            }
        }

        // Draw towers
        for (const t of this.towers) {
            // Range circle (subtle)
            if (this.phase === 'planning') {
                ctx.strokeStyle = `${t.def.color}22`;
                ctx.beginPath();
                ctx.arc(t.x, t.y, t.def.range, 0, Math.PI * 2);
                ctx.stroke();
            }

            // Tower base
            ctx.fillStyle = `${t.def.color}44`;
            ctx.beginPath();
            ctx.arc(t.x, t.y, 14, 0, Math.PI * 2);
            ctx.fill();
            ctx.strokeStyle = t.def.color;
            ctx.lineWidth = 2;
            ctx.stroke();

            // Tower icon
            ctx.font = '16px sans-serif';
            ctx.textAlign = 'center';
            ctx.textBaseline = 'middle';
            ctx.fillText(t.def.icon, t.x, t.y);

            // SCM boost ring
            if (t.def.id === 'scm') {
                ctx.strokeStyle = `#0f044`;
                ctx.setLineDash([4, 4]);
                ctx.beginPath();
                ctx.arc(t.x, t.y, t.def.range, 0, Math.PI * 2);
                ctx.stroke();
                ctx.setLineDash([]);
            }

            // Barrel direction
            if (t.targetAngle !== undefined) {
                ctx.strokeStyle = t.def.color;
                ctx.lineWidth = 2;
                ctx.beginPath();
                ctx.moveTo(t.x, t.y);
                ctx.lineTo(t.x + Math.cos(t.targetAngle) * 16, t.y + Math.sin(t.targetAngle) * 16);
                ctx.stroke();
            }
        }

        // Draw factories
        for (const f of this.factories) {
            const pct = f.hp / f.maxHp;
            const glow = pct > 0.5 ? '#0af' : pct > 0.2 ? '#fa0' : '#f22';

            // Glow
            ctx.shadowColor = glow;
            ctx.shadowBlur = 15 + Math.sin(this.tick * 0.05) * 5;

            // Factory icon
            ctx.fillStyle = glow;
            ctx.beginPath();
            ctx.moveTo(f.x, f.y - 16);
            ctx.lineTo(f.x + 12, f.y + 8);
            ctx.lineTo(f.x - 12, f.y + 8);
            ctx.closePath();
            ctx.fill();

            ctx.shadowBlur = 0;

            // Factory border
            ctx.strokeStyle = '#fff';
            ctx.lineWidth = 1.5;
            ctx.stroke();

            // HP bar
            const bw = 30, bh = 4;
            ctx.fillStyle = '#111';
            ctx.fillRect(f.x - bw / 2, f.y + 13, bw, bh);
            ctx.fillStyle = glow;
            ctx.fillRect(f.x - bw / 2, f.y + 13, bw * pct, bh);

            // Name
            ctx.font = 'bold 9px sans-serif';
            ctx.fillStyle = '#cde';
            ctx.textAlign = 'center';
            ctx.fillText(f.shortName, f.x, f.y + 26);
        }

        // Draw enemies
        for (const e of this.enemies) {
            // Enemy glow
            ctx.shadowColor = e.color;
            ctx.shadowBlur = 8;

            ctx.fillStyle = e.color;
            ctx.beginPath();
            ctx.arc(e.x, e.y, e.size, 0, Math.PI * 2);
            ctx.fill();

            ctx.shadowBlur = 0;

            // Inner
            ctx.fillStyle = '#fff';
            ctx.beginPath();
            ctx.arc(e.x, e.y, e.size * 0.4, 0, Math.PI * 2);
            ctx.fill();

            // HP bar
            if (e.hp < e.maxHp) {
                const pct = e.hp / e.maxHp;
                const bw = e.size * 2;
                ctx.fillStyle = '#333';
                ctx.fillRect(e.x - bw / 2, e.y - e.size - 6, bw, 3);
                ctx.fillStyle = pct > 0.5 ? '#0f0' : pct > 0.25 ? '#fa0' : '#f00';
                ctx.fillRect(e.x - bw / 2, e.y - e.size - 6, bw * pct, 3);
            }

            // Slow indicator
            if (e.slowTimer > 0) {
                ctx.strokeStyle = '#4cf';
                ctx.lineWidth = 1;
                ctx.beginPath();
                ctx.arc(e.x, e.y, e.size + 3, 0, Math.PI * 2);
                ctx.stroke();
            }
        }

        // Draw projectiles
        for (const p of this.projectiles) {
            // Trail
            for (let j = 0; j < p.trail.length; j++) {
                const alpha = j / p.trail.length * 0.5;
                ctx.fillStyle = p.color + Math.floor(alpha * 255).toString(16).padStart(2, '0');
                ctx.beginPath();
                ctx.arc(p.trail[j].x, p.trail[j].y, 2, 0, Math.PI * 2);
                ctx.fill();
            }
            // Head
            ctx.fillStyle = '#fff';
            ctx.beginPath();
            ctx.arc(p.x, p.y, 3, 0, Math.PI * 2);
            ctx.fill();
        }

        // Draw particles
        for (const p of this.particles) {
            const alpha = p.life / p.maxLife;
            ctx.globalAlpha = alpha;
            ctx.fillStyle = p.color;
            ctx.beginPath();
            ctx.arc(p.x, p.y, p.size * alpha, 0, Math.PI * 2);
            ctx.fill();
        }
        ctx.globalAlpha = 1;

        // Wave announcement
        if (this.waveAnnounceTick > 0) {
            const alpha = Math.min(1, this.waveAnnounceTick / 30);
            const scale = 1 + (1 - alpha) * 0.5;
            ctx.save();
            ctx.globalAlpha = alpha;
            ctx.font = `bold ${28 * scale}px sans-serif`;
            ctx.fillStyle = '#f80';
            ctx.textAlign = 'center';
            ctx.textBaseline = 'middle';
            ctx.shadowColor = '#f80';
            ctx.shadowBlur = 20;
            ctx.fillText(`WAVE ${this.wave}`, W / 2, H / 2 - 20);
            ctx.font = `bold ${16 * scale}px sans-serif`;
            ctx.fillStyle = '#fda';
            ctx.fillText(this.waveAnnounceText, W / 2, H / 2 + 15);
            ctx.restore();
        }

        // Combo display
        if (this.comboCount >= 3 && this.comboTimer > 0) {
            ctx.font = 'bold 18px sans-serif';
            ctx.fillStyle = '#ff0';
            ctx.textAlign = 'center';
            ctx.shadowColor = '#ff0';
            ctx.shadowBlur = 10;
            ctx.fillText(`${this.comboCount} COMBO!`, W / 2, 80);
            ctx.shadowBlur = 0;
        }

        // Hover cell indicator
        if (this.selectedTowerId && this.hoverCell && this.phase === 'planning') {
            const def = TOWERS.find(t => t.id === this.selectedTowerId);
            if (def) {
                ctx.strokeStyle = this.canPlaceTower(this.hoverCell.x, this.hoverCell.y) ? '#0f0' : '#f00';
                ctx.lineWidth = 1;
                ctx.strokeRect(this.hoverCell.x - 16, this.hoverCell.y - 16, 32, 32);
            }
        }

        ctx.restore();
    }

    drawMapOutline(ctx) {
        const self = this;
        const drawGeoPoly = (geoPoints, fill, stroke) => {
            if (geoPoints.length < 2) return;
            const pts = geoPoints.map(p => self.geoToCanvas(p[0], p[1]));
            ctx.beginPath();
            ctx.moveTo(pts[0].x, pts[0].y);
            for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y);
            ctx.closePath();
            if (fill) { ctx.fillStyle = fill; ctx.fill(); }
            if (stroke) { ctx.strokeStyle = stroke; ctx.lineWidth = 1.5; ctx.stroke(); }
        };
        const fill = 'rgba(20,40,80,0.4)';
        const stroke = 'rgba(60,120,255,0.3)';
        drawGeoPoly(HONSHU_GEO, fill, stroke);
        drawGeoPoly(KYUSHU_GEO, fill, stroke);
        drawGeoPoly(HOKKAIDO_GEO, fill, stroke);
        drawGeoPoly(SHIKOKU_GEO, fill, stroke);
    }

    // ── Spawning ──
    spawnExplosion(x, y, color, count) {
        for (let i = 0; i < count; i++) {
            const angle = Math.random() * Math.PI * 2;
            const spd = 1 + Math.random() * 3;
            this.particles.push({
                x, y,
                vx: Math.cos(angle) * spd,
                vy: Math.sin(angle) * spd - 1,
                color,
                size: 2 + Math.random() * 3,
                life: 20 + Math.random() * 30,
                maxLife: 50
            });
        }
    }

    // ── Tower Placement ──
    canPlaceTower(x, y) {
        // Not too close to factories
        for (const f of this.factories) {
            if (Math.hypot(f.x - x, f.y - y) < 30) return false;
        }
        // Not too close to other towers
        for (const t of this.towers) {
            if (Math.hypot(t.x - x, t.y - y) < 28) return false;
        }
        return true;
    }

    placeTower(x, y) {
        const def = TOWERS.find(t => t.id === this.selectedTowerId);
        if (!def || this.money < def.cost) return;
        if (!this.canPlaceTower(x, y)) return;
        this.towers.push({ x, y, def: { ...def }, cooldown: 0, targetAngle: 0 });
        this.money -= def.cost;
        this.spawnExplosion(x, y, def.color, 10);
    }

    // ── Wave Start ──
    startWave() {
        this.wave++;
        const waveConf = WAVES[this.wave - 1];
        if (!waveConf) return;

        this.spawnQueue = [];
        const origins = ORIGINS[waveConf.origin] || ORIGINS.south;

        for (const eg of waveConf.enemies) {
            const et = ENEMY_TYPES[eg.type];
            for (let i = 0; i < eg.count; i++) {
                const origin = origins[Math.floor(Math.random() * origins.length)];
                const spread = 40;
                this.spawnQueue.push({
                    x: origin.x + (Math.random() - 0.5) * spread,
                    y: origin.y + (Math.random() - 0.5) * spread,
                    hp: et.hp * (1 + this.wave * 0.1),
                    maxHp: et.hp * (1 + this.wave * 0.1),
                    speed: et.speed,
                    color: et.color,
                    size: et.size,
                    reward: et.reward,
                    name: et.name,
                    angle: 0,
                    slowTimer: 0,
                    slowMult: 1
                });
            }
        }
        // Shuffle spawn order
        for (let i = this.spawnQueue.length - 1; i > 0; i--) {
            const j = Math.floor(Math.random() * (i + 1));
            [this.spawnQueue[i], this.spawnQueue[j]] = [this.spawnQueue[j], this.spawnQueue[i]];
        }
        this.spawnTimer = 0;
        this.phase = 'wave';
        this.waveAnnounceTick = 120;
        this.waveAnnounceText = waveConf.label;
    }

    // ── Game End ──
    gameOver() {
        this.phase = 'gameover';
        this.resultTitle = 'GAME OVER';
        this.resultDetail = `Wave ${this.wave}で全工場が壊滅しました`;
        this.showResult = true;
        this.stopLoop();
    }

    victory() {
        this.phase = 'victory';
        // Bonus for remaining HP
        let hpBonus = 0;
        for (const f of this.factories) {
            hpBonus += Math.max(0, Math.ceil(f.hp)) * 10;
        }
        this.score += hpBonus;
        this.resultTitle = 'VICTORY!';
        this.resultDetail = `全${MAX_WAVES}Wave突破！ HPボーナス: +${hpBonus}`;
        this.showResult = true;
        this.stopLoop();
    }

    // ── Event Handlers ──
    handleGameStart() {
        this.initGame();
        this.gameLoop();
    }

    handleRestart() {
        this.stopLoop();
        this.initGame();
        this.gameLoop();
    }

    handleTowerSelect(event) {
        const id = event.currentTarget.dataset.towerId;
        const def = TOWERS.find(t => t.id === id);
        if (def && this.money >= def.cost) {
            this.selectedTowerId = this.selectedTowerId === id ? null : id;
        }
    }

    handleStartWave() {
        if (this.phase === 'planning') {
            this.startWave();
        }
    }

    handleCanvasClick(event) {
        if (this.phase !== 'planning' || !this.selectedTowerId) return;
        const rect = this.canvas.getBoundingClientRect();
        const scaleX = W / rect.width;
        const scaleY = H / rect.height;
        const x = Math.round((event.clientX - rect.left) * scaleX / 32) * 32 + 16;
        const y = Math.round((event.clientY - rect.top) * scaleY / 32) * 32 + 16;
        this.placeTower(x, y);
    }

    handleCanvasMove(event) {
        if (!this.canvas) return;
        const rect = this.canvas.getBoundingClientRect();
        const scaleX = W / rect.width;
        const scaleY = H / rect.height;
        const x = Math.round((event.clientX - rect.left) * scaleX / 32) * 32 + 16;
        const y = Math.round((event.clientY - rect.top) * scaleY / 32) * 32 + 16;
        this.hoverCell = { x, y };
    }

    // ── Title Render ──
    renderTitle() {
        const ctx = this.ctx;
        if (!ctx) return;
        ctx.fillStyle = '#070720';
        ctx.fillRect(0, 0, W, H);
        this.drawMapOutline(ctx);

        // Animated dots
        const t = Date.now() * 0.001;
        for (let i = 0; i < 50; i++) {
            const x = (Math.sin(t + i * 1.3) * 0.5 + 0.5) * W;
            const y = (Math.cos(t + i * 0.7) * 0.5 + 0.5) * H;
            ctx.fillStyle = `rgba(0,150,255,${0.1 + Math.sin(t + i) * 0.05})`;
            ctx.beginPath();
            ctx.arc(x, y, 1.5, 0, Math.PI * 2);
            ctx.fill();
        }

        if (this.showTitle) {
            requestAnimationFrame(() => this.renderTitle());
        }
    }

    disconnectedCallback() {
        this.stopLoop();
    }
}
