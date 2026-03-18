import { LightningElement, track } from 'lwc';

export default class SimpleCalculator extends LightningElement {
    @track display = '0';
    @track expression = '';

    _currentValue = '';
    _operator = null;
    _prevValue = null;
    _waitingForOperand = false;

    handleNumber(event) {
        const digit = event.target.dataset.value;

        if (this._waitingForOperand) {
            this._currentValue = digit;
            this._waitingForOperand = false;
        } else {
            this._currentValue = this._currentValue === '0'
                ? digit
                : this._currentValue + digit;
        }
        this.display = this._currentValue;
    }

    handleDot() {
        if (this._waitingForOperand) {
            this._currentValue = '0.';
            this._waitingForOperand = false;
            this.display = this._currentValue;
            return;
        }
        if (!this._currentValue.includes('.')) {
            this._currentValue = (this._currentValue || '0') + '.';
            this.display = this._currentValue;
        }
    }

    handleOperator(event) {
        const op = event.target.dataset.value;
        const current = parseFloat(this._currentValue || this.display);

        if (this._operator && !this._waitingForOperand) {
            const result = this._calculate(this._prevValue, current, this._operator);
            this.display = this._formatResult(result);
            this._prevValue = result;
        } else {
            this._prevValue = current;
        }

        this._operator = op;
        this._waitingForOperand = true;
        this.expression = `${this._formatResult(this._prevValue)} ${this._opLabel(op)}`;
        this._currentValue = '';
    }

    handleEqual() {
        if (!this._operator || this._prevValue === null) return;

        const current = parseFloat(this._currentValue || this.display);
        const result = this._calculate(this._prevValue, current, this._operator);

        this.expression = `${this._formatResult(this._prevValue)} ${this._opLabel(this._operator)} ${this._formatResult(current)} =`;
        this.display = this._formatResult(result);
        this._currentValue = String(result);
        this._operator = null;
        this._prevValue = null;
        this._waitingForOperand = true;
    }

    handleClear() {
        this.display = '0';
        this.expression = '';
        this._currentValue = '';
        this._operator = null;
        this._prevValue = null;
        this._waitingForOperand = false;
    }

    handleToggleSign() {
        const val = parseFloat(this.display);
        if (!isNaN(val) && val !== 0) {
            const toggled = val * -1;
            this._currentValue = String(toggled);
            this.display = this._formatResult(toggled);
        }
    }

    _calculate(a, b, op) {
        switch (op) {
            case '+': return a + b;
            case '-': return a - b;
            case '*': return a * b;
            case '/': return b !== 0 ? a / b : 'Error';
            default:  return b;
        }
    }

    _formatResult(val) {
        if (val === 'Error') return 'Error';
        const num = parseFloat(val);
        if (isNaN(num)) return '0';
        // 小数点以下10桁で丸めて、末尾ゼロを除去
        return parseFloat(num.toFixed(10)).toString();
    }

    _opLabel(op) {
        const map = { '+': '+', '-': '-', '*': '×', '/': '÷' };
        return map[op] || op;
    }
}
