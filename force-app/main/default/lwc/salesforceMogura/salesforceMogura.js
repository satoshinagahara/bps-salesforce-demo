import { LightningElement, track } from 'lwc';

const CHARACTERS = [
    { name: 'Astro', emoji: '🚀', points: 10, weight: 40, pointLabel: '10pt' },
    { name: 'Codey', emoji: '🐻', points: 20, weight: 30, pointLabel: '20pt' },
    { name: 'Appy', emoji: '💎', points: 30, weight: 15, pointLabel: '30pt' },
    { name: 'Einstein', emoji: '🧠', points: 50, weight: 10, pointLabel: '50pt' },
    { name: 'SaaSy', emoji: '👑', points: 100, weight: 5, pointLabel: '100pt' }
];

const DIFFICULTIES = [
    { value: 'easy', label: '🟢 やさしい', time: 45, baseInterval: 1200, minInterval: 600, moleStay: 1500 },
    { value: 'normal', label: '🟡 ふつう', time: 40, baseInterval: 900, minInterval: 400, moleStay: 1100 },
    { value: 'hard', label: '🔴 むずかしい', time: 35, baseInterval: 650, minInterval: 250, moleStay: 750 }
];

const GRID_SIZE = 9;
const LEVEL_UP_SCORE = 300;
const GAME_TIME = 40;

const RANKS = [
    { name: 'TRAILBLAZER', threshold: 1500, emoji: '🏆' },
    { name: 'RANGER', threshold: 1000, emoji: '⭐' },
    { name: 'HIKER', threshold: 600, emoji: '🥾' },
    { name: 'SCOUT', threshold: 300, emoji: '🔍' },
    { name: 'BEGINNER', threshold: 0, emoji: '🌱' }
];

export default class SalesforceMogura extends LightningElement {
    @track screen = 'start';
    @track selectedDifficulty = 'normal';
    @track score = 0;
    @track combo = 0;
    @track maxCombo = 0;
    @track level = 1;
    @track timeLeft = GAME_TIME;
    @track totalHits = 0;
    @track totalMisses = 0;
    @track holes = [];
    @track showHitEffect = false;
    @track hitPoints = 0;
    @track hitEffectX = 0;
    @track hitEffectY = 0;

    _gameTimerId = null;
    _spawnTimerId = null;
    _hitEffectTimerId = null;
    _activeMoles = new Map(); // holeId -> timeoutId

    get characterList() { return CHARACTERS; }

    get isStartScreen() { return this.screen === 'start'; }
    get isGameScreen() { return this.screen === 'game'; }
    get isResultScreen() { return this.screen === 'result'; }

    get difficulties() {
        return DIFFICULTIES.map(d => ({
            ...d,
            className: 'diff-btn' + (this.selectedDifficulty === d.value ? ' selected' : '')
        }));
    }

    get difficultyConfig() {
        return DIFFICULTIES.find(d => d.value === this.selectedDifficulty) || DIFFICULTIES[1];
    }

    get comboDisplay() {
        return this.combo > 1 ? `${this.combo}x COMBO!` : '-';
    }

    get comboClass() {
        if (this.combo >= 10) return 'header-value combo-fire';
        if (this.combo >= 5) return 'header-value combo-hot';
        if (this.combo > 1) return 'header-value combo-active';
        return 'header-value';
    }

    get timerClass() {
        if (this.timeLeft <= 5) return 'header-value timer-danger';
        if (this.timeLeft <= 10) return 'header-value timer-warning';
        return 'header-value';
    }

    get timerBarStyle() {
        const config = this.difficultyConfig;
        const pct = (this.timeLeft / config.time) * 100;
        return `width: ${Math.max(0, pct)}%`;
    }

    get timerBarClass() {
        if (this.timeLeft <= 5) return 'timer-bar danger';
        if (this.timeLeft <= 10) return 'timer-bar warning';
        return 'timer-bar';
    }

    get hitEffectStyle() {
        return `left: ${this.hitEffectX}px; top: ${this.hitEffectY}px;`;
    }

    get currentRank() {
        return RANKS.find(r => this.score >= r.threshold) || RANKS[RANKS.length - 1];
    }

    get rankEmoji() { return this.currentRank.emoji; }
    get rankName() { return this.currentRank.name; }

    // --- Handlers ---
    handleDifficultySelect(event) {
        this.selectedDifficulty = event.currentTarget.dataset.value;
    }

    handleStart() {
        this.resetGame();
        const config = this.difficultyConfig;
        this.timeLeft = config.time;
        this.screen = 'game';
        this.initHoles();
        this.startGameTimer();
        this.scheduleNextSpawn();
    }

    handleWhack(event) {
        const holeId = parseInt(event.currentTarget.dataset.id, 10);
        const hole = this.holes.find(h => h.id === holeId);

        if (!hole || !hole.isActive) {
            // Miss
            this.combo = 0;
            this.totalMisses++;
            return;
        }

        // Hit!
        const character = hole.character;
        this.combo++;
        if (this.combo > this.maxCombo) {
            this.maxCombo = this.combo;
        }
        this.totalHits++;

        const comboMultiplier = Math.min(this.combo, 10);
        const points = character.points * comboMultiplier;
        this.score += points;
        this.hitPoints = points;

        // Level up
        const newLevel = Math.floor(this.score / LEVEL_UP_SCORE) + 1;
        if (newLevel > this.level) {
            this.level = newLevel;
        }

        // Show hit effect
        this.showHitEffect = true;
        if (this._hitEffectTimerId) clearTimeout(this._hitEffectTimerId);
        this._hitEffectTimerId = setTimeout(() => {
            this.showHitEffect = false;
        }, 600);

        // Clear mole
        this.clearMole(holeId);

        // Mark as whacked (for animation)
        this.updateHole(holeId, { isActive: false, isWhacked: true, character: null, emoji: '' });
        setTimeout(() => {
            this.updateHole(holeId, { isWhacked: false });
        }, 200);
    }

    handleRetry() {
        this.handleStart();
    }

    handleBack() {
        this.screen = 'start';
    }

    // --- Game Logic ---
    initHoles() {
        const arr = [];
        for (let i = 0; i < GRID_SIZE; i++) {
            arr.push({
                id: i,
                isActive: false,
                isWhacked: false,
                character: null,
                emoji: '',
                holeClass: 'hole',
                moleClass: 'mole'
            });
        }
        this.holes = arr;
    }

    startGameTimer() {
        this._gameTimerId = setInterval(() => {
            this.timeLeft--;
            if (this.timeLeft <= 0) {
                this.endGame();
            }
        }, 1000);
    }

    scheduleNextSpawn() {
        const config = this.difficultyConfig;
        const speedFactor = Math.max(0.4, 1 - (this.level - 1) * 0.08);
        const interval = Math.max(config.minInterval, config.baseInterval * speedFactor);
        const randomOffset = (Math.random() - 0.5) * interval * 0.5;

        this._spawnTimerId = setTimeout(() => {
            if (this.screen === 'game') {
                this.spawnMole();
                this.scheduleNextSpawn();
            }
        }, interval + randomOffset);
    }

    spawnMole() {
        // Find inactive holes
        const inactiveHoles = this.holes.filter(h => !h.isActive);
        if (inactiveHoles.length === 0) return;

        const hole = inactiveHoles[Math.floor(Math.random() * inactiveHoles.length)];
        const character = this.pickCharacter();

        const config = this.difficultyConfig;
        const stayTime = config.moleStay * Math.max(0.5, 1 - (this.level - 1) * 0.05);

        this.updateHole(hole.id, {
            isActive: true,
            character: character,
            emoji: character.emoji,
            moleClass: 'mole mole-appear'
        });

        // Auto-hide after stayTime
        const timeoutId = setTimeout(() => {
            this.clearMole(hole.id);
            const currentHole = this.holes.find(h => h.id === hole.id);
            if (currentHole && currentHole.isActive) {
                this.updateHole(hole.id, { isActive: false, character: null, emoji: '' });
                // Reset combo on miss (mole escaped)
                this.combo = 0;
            }
        }, stayTime);

        this._activeMoles.set(hole.id, timeoutId);

        // Spawn extra moles at higher levels
        if (this.level >= 3 && Math.random() < 0.3) {
            setTimeout(() => this.spawnMole(), 200);
        }
        if (this.level >= 6 && Math.random() < 0.2) {
            setTimeout(() => this.spawnMole(), 400);
        }
    }

    pickCharacter() {
        const totalWeight = CHARACTERS.reduce((sum, c) => sum + c.weight, 0);
        let rand = Math.random() * totalWeight;
        for (const ch of CHARACTERS) {
            rand -= ch.weight;
            if (rand <= 0) return ch;
        }
        return CHARACTERS[0];
    }

    clearMole(holeId) {
        const timeoutId = this._activeMoles.get(holeId);
        if (timeoutId) {
            clearTimeout(timeoutId);
            this._activeMoles.delete(holeId);
        }
    }

    updateHole(holeId, updates) {
        this.holes = this.holes.map(h => {
            if (h.id === holeId) {
                const updated = { ...h, ...updates };
                updated.holeClass = 'hole' +
                    (updated.isActive ? ' hole-active' : '') +
                    (updated.isWhacked ? ' hole-whacked' : '');
                return updated;
            }
            return h;
        });
    }

    endGame() {
        this.stopTimers();
        this.screen = 'result';
    }

    stopTimers() {
        if (this._gameTimerId) {
            clearInterval(this._gameTimerId);
            this._gameTimerId = null;
        }
        if (this._spawnTimerId) {
            clearTimeout(this._spawnTimerId);
            this._spawnTimerId = null;
        }
        if (this._hitEffectTimerId) {
            clearTimeout(this._hitEffectTimerId);
            this._hitEffectTimerId = null;
        }
        for (const [, timeoutId] of this._activeMoles) {
            clearTimeout(timeoutId);
        }
        this._activeMoles.clear();
    }

    resetGame() {
        this.stopTimers();
        this.score = 0;
        this.combo = 0;
        this.maxCombo = 0;
        this.level = 1;
        this.totalHits = 0;
        this.totalMisses = 0;
        this.showHitEffect = false;
        this.holes = [];
    }

    disconnectedCallback() {
        this.stopTimers();
    }
}
