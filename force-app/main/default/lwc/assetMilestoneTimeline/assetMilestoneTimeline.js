import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getMilestones from '@salesforce/apex/AssetMilestoneController.getMilestones';

const TYPE_ICON = {
    '納品設置': '🚚',
    '試運転': '⚙️',
    '定期点検': '🔧',
    '部品交換': '🛠',
    '保守訪問': '👷',
    'ファームウェア更新': '💿',
    '故障対応': '🚨',
    '保守契約更新': '📑',
    '保守期限': '⏳',
    '解約': '✖'
};

export default class AssetMilestoneTimeline extends LightningElement {
    @api recordId;
    @track items = [];
    error;
    wiredResult;
    todayStr;
    _todayInserted = false;

    connectedCallback() {
        const d = new Date();
        const y = d.getFullYear();
        const m = String(d.getMonth() + 1).padStart(2, '0');
        const day = String(d.getDate()).padStart(2, '0');
        this.todayStr = `${y}-${m}-${day}`;
    }

    @wire(getMilestones, { assetId: '$recordId' })
    wired(result) {
        this.wiredResult = result;
        if (result.data) {
            this.items = this._decorate(result.data);
        } else if (result.error) {
            this.error = result.error;
        }
    }

    _decorate(raw) {
        // 今日の位置にマーカーを挿入するため、raw配列の中で最初に「未来」になる位置を探す
        const list = [];
        let todayInserted = false;
        const today = new Date();
        today.setHours(0, 0, 0, 0);

        raw.forEach((m, idx) => {
            const schedDate = new Date(m.scheduledDate);
            if (!todayInserted && schedDate > today) {
                list.push({
                    __isTodayMarker: true,
                    key: 'today-marker',
                    label: this._formatToday()
                });
                todayInserted = true;
            }

            let cssClass = 'ms-item';
            let iconChar;
            if (m.isCompleted) {
                cssClass += ' ms-done';
                iconChar = '✓';
            } else if (m.isPast) {
                cssClass += ' ms-late';
                iconChar = '!';
            } else if (m.isNear) {
                cssClass += ' ms-near';
                iconChar = '◐';
            } else {
                cssClass += ' ms-future';
                iconChar = '○';
            }

            // 保守期限・解約は強調
            if (m.milestoneType === '保守期限' || m.milestoneType === '解約') {
                cssClass += ' ms-warn';
            }

            const typeIcon = TYPE_ICON[m.milestoneType] || '•';
            const dateLabel = this._formatDate(m.scheduledDate);
            const completedLabel = m.completedDate ? `（実施: ${this._formatDate(m.completedDate)}）` : '';

            let countdown = '';
            if (m.isFuture && m.daysFromToday <= 60) {
                countdown = `残り${m.daysFromToday}日`;
            } else if (m.isToday) {
                countdown = '本日';
            }

            list.push({
                ...m,
                key: m.id,
                cssClass,
                iconChar,
                typeIcon,
                dateLabel,
                completedLabel,
                countdown,
                __isTodayMarker: false
            });
        });

        if (!todayInserted) {
            list.push({
                __isTodayMarker: true,
                key: 'today-marker',
                label: this._formatToday()
            });
        }
        return list;
    }

    _formatDate(d) {
        if (!d) return '';
        const dt = new Date(d);
        const y = dt.getFullYear();
        const m = String(dt.getMonth() + 1).padStart(2, '0');
        const day = String(dt.getDate()).padStart(2, '0');
        return `${y}/${m}/${day}`;
    }

    _formatToday() {
        const dt = new Date();
        const y = dt.getFullYear();
        const m = String(dt.getMonth() + 1).padStart(2, '0');
        const day = String(dt.getDate()).padStart(2, '0');
        return `本日 ${y}/${m}/${day}`;
    }

    handleRefresh() {
        return refreshApex(this.wiredResult);
    }
}
