import { LightningElement, track } from 'lwc';
import generateQuiz from '@salesforce/apex/SalesforceQuizController.generateQuiz';

const CATEGORIES = [
    { value: 'Admin（管理者）', label: 'Admin', icon: '🛠️' },
    { value: 'Developer（開発者）', label: 'Developer', icon: '💻' },
    { value: 'Flow（フロー/自動化）', label: 'Flow', icon: '⚡' },
    { value: 'セキュリティ/共有設定', label: 'セキュリティ', icon: '🔒' },
    { value: 'レポート/ダッシュボード', label: 'レポート', icon: '📊' },
    { value: 'データモデリング/オブジェクト設計', label: 'データモデル', icon: '🗄️' }
];

const DIFFICULTIES = [
    { value: '初級（基礎知識レベル）', label: '★☆☆ 初級' },
    { value: '中級（認定試験レベル）', label: '★★☆ 中級' },
    { value: '上級（実務応用レベル）', label: '★★★ 上級' }
];

const RANKS = [
    { name: 'TRAILBLAZER', stars: '★★★★★', threshold: 90, emoji: '🏆' },
    { name: 'RANGER', stars: '⭐⭐⭐⭐', threshold: 80, emoji: '⭐' },
    { name: 'HIKER', stars: '⭐⭐⭐', threshold: 60, emoji: '🥾' },
    { name: 'SCOUT', stars: '⭐⭐', threshold: 40, emoji: '🔍' },
    { name: 'BEGINNER', stars: '⭐', threshold: 0, emoji: '🌱' }
];

const QUESTION_TIME_LIMIT = 30;
const BASE_SCORE = 100;
const MAX_BONUS = 50;

export default class SalesforceQuizBattle extends LightningElement {
    @track screen = 'start'; // start, loading, quiz, result
    @track selectedCategory = CATEGORIES[0].value;
    @track selectedDifficulty = DIFFICULTIES[1].value;
    @track questions = [];
    @track currentIndex = 0;
    @track totalScore = 0;
    @track correctCount = 0;
    @track selectedAnswer = null;
    @track isAnswered = false;
    @track isCorrect = false;
    @track questionScore = 0;
    @track bonusScore = 0;
    @track timeLeft = QUESTION_TIME_LIMIT;
    @track answerTimes = [];
    @track errorMessage = null;

    _timerId = null;
    _questionStartTime = null;

    // --- Screen State ---
    get isStartScreen() { return this.screen === 'start'; }
    get isLoading() { return this.screen === 'loading'; }
    get isQuizScreen() { return this.screen === 'quiz'; }
    get isResultScreen() { return this.screen === 'result'; }

    // --- Categories & Difficulties with selection state ---
    get categories() {
        return CATEGORIES.map(c => ({
            ...c,
            className: 'cat-btn' + (this.selectedCategory === c.value ? ' selected' : '')
        }));
    }

    get difficulties() {
        return DIFFICULTIES.map(d => ({
            ...d,
            className: 'diff-btn' + (this.selectedDifficulty === d.value ? ' selected' : '')
        }));
    }

    get selectedCategoryLabel() {
        const cat = CATEGORIES.find(c => c.value === this.selectedCategory);
        return cat ? `${cat.icon} ${cat.label}` : '';
    }

    get selectedDifficultyLabel() {
        const diff = DIFFICULTIES.find(d => d.value === this.selectedDifficulty);
        return diff ? diff.label : '';
    }

    // --- Quiz State ---
    get currentQuestion() {
        return this.questions[this.currentIndex] || {};
    }

    get currentQuestionNum() {
        return this.currentIndex + 1;
    }

    get totalQuestions() {
        return this.questions.length;
    }

    get currentChoices() {
        const q = this.currentQuestion;
        if (!q.choices) return [];
        return q.choices.map(c => {
            let className = 'choice-btn';
            let icon = null;
            if (this.isAnswered) {
                if (c.label === q.answer) {
                    className += ' correct';
                    icon = '✅';
                } else if (c.label === this.selectedAnswer) {
                    className += ' incorrect';
                    icon = '❌';
                } else {
                    className += ' disabled';
                }
            }
            return { ...c, className, icon };
        });
    }

    get formattedTime() {
        const secs = Math.max(0, Math.ceil(this.timeLeft));
        return String(secs).padStart(2, '0');
    }

    get progressBarStyle() {
        const pct = this.totalQuestions > 0
            ? (this.currentIndex / this.totalQuestions) * 100
            : 0;
        return `width: ${pct}%`;
    }

    get timerBarStyle() {
        const pct = (this.timeLeft / QUESTION_TIME_LIMIT) * 100;
        return `width: ${Math.max(0, pct)}%`;
    }

    get timerBarClass() {
        if (this.timeLeft <= 5) return 'timer-bar danger';
        if (this.timeLeft <= 10) return 'timer-bar warning';
        return 'timer-bar';
    }

    get hasBonus() {
        return this.bonusScore > 0;
    }

    get feedbackClass() {
        return 'feedback ' + (this.isCorrect ? 'feedback-correct' : 'feedback-incorrect');
    }

    get nextButtonLabel() {
        return this.currentIndex < this.questions.length - 1 ? '次の問題' : '結果を見る';
    }

    // --- Result State ---
    get maxScore() {
        return this.totalQuestions * (BASE_SCORE + MAX_BONUS);
    }

    get correctRate() {
        return this.totalQuestions > 0
            ? Math.round((this.correctCount / this.totalQuestions) * 100)
            : 0;
    }

    get avgAnswerTime() {
        if (this.answerTimes.length === 0) return '0.0';
        const avg = this.answerTimes.reduce((a, b) => a + b, 0) / this.answerTimes.length;
        return avg.toFixed(1);
    }

    get currentRank() {
        const rate = this.correctRate;
        return RANKS.find(r => rate >= r.threshold) || RANKS[RANKS.length - 1];
    }

    get rankEmoji() { return this.currentRank.emoji; }
    get rankName() { return this.currentRank.name; }

    get rankList() {
        return RANKS.map(r => ({
            ...r,
            requirement: `${r.threshold}%以上`,
            className: 'rank-row' + (r.name === this.currentRank.name ? ' current-rank' : '')
        }));
    }

    // --- Handlers ---
    handleCategorySelect(event) {
        this.selectedCategory = event.currentTarget.dataset.value;
    }

    handleDifficultySelect(event) {
        this.selectedDifficulty = event.currentTarget.dataset.value;
    }

    async handleStart() {
        this.screen = 'loading';
        this.resetQuizState();

        try {
            const result = await generateQuiz({
                category: this.selectedCategory,
                difficulty: this.selectedDifficulty
            });

            const parsed = this.parseQuizJson(result);
            if (parsed.length === 0) {
                this.errorMessage = 'クイズの生成に失敗しました。もう一度お試しください。';
                this.screen = 'start';
                return;
            }

            this.questions = parsed;
            this.screen = 'quiz';
            this.startTimer();
        } catch (error) {
            console.error('Quiz generation error:', error);
            this.errorMessage = error.body?.message || 'エラーが発生しました。';
            this.screen = 'start';
        }
    }

    handleAnswer(event) {
        if (this.isAnswered) return;

        const selected = event.currentTarget.dataset.label;
        this.selectedAnswer = selected;
        this.isAnswered = true;
        this.stopTimer();

        const elapsed = (Date.now() - this._questionStartTime) / 1000;
        this.answerTimes.push(Math.round(elapsed * 10) / 10);

        const q = this.currentQuestion;
        this.isCorrect = selected === q.answer;

        if (this.isCorrect) {
            const remainingSecs = Math.max(0, this.timeLeft);
            this.bonusScore = Math.round((remainingSecs / QUESTION_TIME_LIMIT) * MAX_BONUS);
            this.questionScore = BASE_SCORE + this.bonusScore;
            this.totalScore += this.questionScore;
            this.correctCount++;
        } else {
            this.questionScore = 0;
            this.bonusScore = 0;
        }
    }

    handleNext() {
        if (this.currentIndex < this.questions.length - 1) {
            this.currentIndex++;
            this.isAnswered = false;
            this.isCorrect = false;
            this.selectedAnswer = null;
            this.questionScore = 0;
            this.bonusScore = 0;
            this.timeLeft = QUESTION_TIME_LIMIT;
            this.startTimer();
        } else {
            this.screen = 'result';
        }
    }

    handleRetry() {
        this.resetQuizState();
        this.handleStart();
    }

    handleChangeCategory() {
        this.resetQuizState();
        this.screen = 'start';
    }

    // --- Timer ---
    startTimer() {
        this.stopTimer();
        this.timeLeft = QUESTION_TIME_LIMIT;
        this._questionStartTime = Date.now();

        this._timerId = setInterval(() => {
            const elapsed = (Date.now() - this._questionStartTime) / 1000;
            this.timeLeft = QUESTION_TIME_LIMIT - elapsed;

            if (this.timeLeft <= 0) {
                this.timeLeft = 0;
                this.handleTimeUp();
            }
        }, 100);
    }

    stopTimer() {
        if (this._timerId) {
            clearInterval(this._timerId);
            this._timerId = null;
        }
    }

    handleTimeUp() {
        if (this.isAnswered) return;
        this.stopTimer();
        this.isAnswered = true;
        this.isCorrect = false;
        this.selectedAnswer = null;
        this.questionScore = 0;
        this.bonusScore = 0;
        this.answerTimes.push(QUESTION_TIME_LIMIT);
    }

    disconnectedCallback() {
        this.stopTimer();
    }

    // --- Helpers ---
    resetQuizState() {
        this.questions = [];
        this.currentIndex = 0;
        this.totalScore = 0;
        this.correctCount = 0;
        this.selectedAnswer = null;
        this.isAnswered = false;
        this.isCorrect = false;
        this.questionScore = 0;
        this.bonusScore = 0;
        this.timeLeft = QUESTION_TIME_LIMIT;
        this.answerTimes = [];
        this.errorMessage = null;
        this.stopTimer();
    }

    parseQuizJson(text) {
        try {
            // Extract JSON array from response (may have markdown code fences)
            let json = text;
            const match = text.match(/\[[\s\S]*\]/);
            if (match) {
                json = match[0];
            }
            const parsed = JSON.parse(json);
            if (Array.isArray(parsed) && parsed.length > 0) {
                return parsed.filter(q =>
                    q.question && q.choices && q.answer && q.explanation
                );
            }
        } catch (e) {
            console.error('JSON parse error:', e, text);
        }
        return [];
    }
}
