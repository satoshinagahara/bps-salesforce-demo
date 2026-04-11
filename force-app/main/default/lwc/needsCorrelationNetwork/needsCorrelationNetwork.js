import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getCorrelationData from '@salesforce/apex/NeedsCorrelationController.getCorrelationData';

const INDUSTRY_META = {
    'Utilities':          { color: '#0891b2', label: '電力・ガス' },
    'Electronics':        { color: '#2563eb', label: 'エレクトロニクス' },
    'Trading':            { color: '#d97706', label: '商社' },
    'Government':         { color: '#475569', label: '官公庁' },
    'Chemicals':          { color: '#7c3aed', label: '化学' },
    'Financial Services': { color: '#059669', label: '金融サービス' },
    'Energy':             { color: '#dc2626', label: 'エネルギー' },
    'Manufacturing':      { color: '#1d4ed8', label: '製造' },
    'Healthcare':         { color: '#e11d48', label: '医療' },
    'Retail':             { color: '#16a34a', label: '小売' },
    'Technology':         { color: '#0ea5e9', label: 'IT' },
    'Unknown':            { color: '#9ca3af', label: '不明' }
};
const DEFAULT_META = { color: '#9ca3af', label: 'その他' };

export default class NeedsCorrelationNetwork extends NavigationMixin(LightningElement) {
    minSimilarity = 15;
    maxNodes = 50;

    rawNodes = [];
    rawEdges = [];
    nodes = [];
    edges = [];
    crossIndustryInsights = [];
    industryCount = {};
    enabledIndustries = new Set();

    canvas;
    ctx;
    width = 800;
    height = 600;

    selectedNode = null;
    hoveredNode = null;
    draggingNode = null;
    isDragging = false;
    dragDistance = 0;
    isStable = false;
    animationId = null;

    tooltipVisible = false;
    tooltipX = 0;
    tooltipY = 0;
    tooltipData = null;

    isLoading = true;
    error;

    get similarityOptions() {
        return [
            { label: '10%', value: 10 },
            { label: '15%', value: 15 },
            { label: '20%', value: 20 },
            { label: '25%', value: 25 },
            { label: '30%', value: 30 }
        ];
    }

    get nodeCountOptions() {
        return [
            { label: '30件', value: 30 },
            { label: '50件', value: 50 },
            { label: '100件', value: 100 }
        ];
    }

    @wire(getCorrelationData, { minSimilarity: '$minSimilarity', maxNodes: '$maxNodes' })
    wiredData({ data, error }) {
        if (data) {
            this.processData(data);
            this.isLoading = false;
            this.error = undefined;
        } else if (error) {
            this.isLoading = false;
            this.error = error.body ? error.body.message : 'データ取得エラー';
        }
    }

    processData(data) {
        this.industryCount = data.industryCount || {};
        this.enabledIndustries = new Set(Object.keys(this.industryCount));

        this.rawNodes = data.nodes.map((n) => ({
            ...n,
            meta: INDUSTRY_META[n.industry] || DEFAULT_META
        }));
        this.rawEdges = data.edges || [];
        this.crossIndustryInsights = data.crossIndustryInsights || [];

        this.rebuildGraph();
    }

    rebuildGraph() {
        const activeNodes = this.rawNodes.filter((n) => this.enabledIndustries.has(n.industry));

        const grouped = {};
        for (const n of activeNodes) {
            if (!grouped[n.industry]) grouped[n.industry] = [];
            grouped[n.industry].push(n);
        }
        const industries = Object.keys(grouped);

        const cx = this.width / 2;
        const cy = this.height / 2;
        // Use more of the canvas — larger ring for cluster centers
        const bigR = Math.min(this.width, this.height) * 0.38;

        const placed = {};
        industries.forEach((ind, idx) => {
            const angle = (idx / Math.max(industries.length, 1)) * Math.PI * 2 - Math.PI / 2;
            // Single-industry case: put cluster at center
            const useCx = industries.length === 1 ? cx : cx + Math.cos(angle) * bigR;
            const useCy = industries.length === 1 ? cy : cy + Math.sin(angle) * bigR;
            const group = grouped[ind];
            const clusterR = 30 + Math.sqrt(group.length) * 14;
            group.forEach((n, i) => {
                const na = (i / Math.max(group.length, 1)) * Math.PI * 2;
                placed[n.id] = {
                    ...n,
                    x: useCx + Math.cos(na) * clusterR,
                    y: useCy + Math.sin(na) * clusterR,
                    vx: 0,
                    vy: 0,
                    radius: 10,
                    color: n.meta.color
                };
            });
        });
        this.nodes = Object.values(placed);

        const nodeById = new Map(this.nodes.map((n) => [n.id, n]));
        this.edges = this.rawEdges
            .filter((e) => nodeById.has(e.from) && nodeById.has(e.to))
            .map((e) => ({
                ...e,
                fromNode: nodeById.get(e.from),
                toNode: nodeById.get(e.to)
            }));

        this.isStable = false;
    }

    get legendItems() {
        return Object.keys(this.industryCount).map((ind) => {
            const meta = INDUSTRY_META[ind] || DEFAULT_META;
            const active = this.enabledIndustries.has(ind);
            return {
                industry: ind,
                label: meta.label,
                color: meta.color,
                dotStyle: `background:${meta.color};`,
                count: this.industryCount[ind],
                active,
                cssClass: active ? 'legend-item' : 'legend-item legend-item--off'
            };
        });
    }

    handleLegendClick(event) {
        const industry = event.currentTarget.dataset.industry;
        if (this.enabledIndustries.has(industry)) {
            this.enabledIndustries.delete(industry);
        } else {
            this.enabledIndustries.add(industry);
        }
        this.enabledIndustries = new Set(this.enabledIndustries);
        this.rebuildGraph();
    }

    renderedCallback() {
        if (!this.canvas && !this.isLoading) {
            this.initCanvas();
        }
    }

    initCanvas() {
        const container = this.template.querySelector('.canvas-container');
        if (!container) return;
        this.canvas = this.template.querySelector('canvas');
        if (!this.canvas) return;

        this.ctx = this.canvas.getContext('2d');

        // Defer one frame to ensure container has real width
        requestAnimationFrame(() => {
            const rect = this.canvas.getBoundingClientRect();
            this.width = Math.max(rect.width, 600);
            this.height = 600;
            this.canvas.width = this.width;
            this.canvas.height = this.height;
            this.rebuildGraph();
        });

        this.canvas.addEventListener('mousedown', this.handleMouseDown.bind(this));
        this.canvas.addEventListener('mousemove', this.handleMouseMove.bind(this));
        this.canvas.addEventListener('mouseup', this.handleMouseUp.bind(this));
        this.canvas.addEventListener('mouseleave', this.handleMouseLeave.bind(this));
        this.canvas.addEventListener('click', this.handleClick.bind(this));

        this.startAnimation();
    }

    startAnimation() {
        const animate = () => {
            if (!this.isStable || this.draggingNode) {
                this.updatePositions();
            }
            this.draw();
            this.animationId = requestAnimationFrame(animate);
        };
        animate();
    }

    updatePositions() {
        const k = 0.015;
        const damping = 0.85;
        const repulsion = 4500;
        const minVelocity = 0.15;
        let maxVelocity = 0;

        for (let i = 0; i < this.nodes.length; i++) {
            const node1 = this.nodes[i];
            if (node1 === this.draggingNode) continue;

            let fx = 0, fy = 0;

            for (let j = 0; j < this.nodes.length; j++) {
                if (i === j) continue;
                const node2 = this.nodes[j];
                const dx = node1.x - node2.x;
                const dy = node1.y - node2.y;
                const dist = Math.max(Math.sqrt(dx * dx + dy * dy), 40);
                const force = repulsion / (dist * dist);
                fx += (dx / dist) * force;
                fy += (dy / dist) * force;
            }

            for (const edge of this.edges) {
                let other = null;
                if (edge.fromNode === node1) other = edge.toNode;
                if (edge.toNode === node1) other = edge.fromNode;
                if (other) {
                    const dx = other.x - node1.x;
                    const dy = other.y - node1.y;
                    const dist = Math.sqrt(dx * dx + dy * dy) || 1;
                    const idealDist = 130;
                    const diff = dist - idealDist;
                    fx += (dx / dist) * diff * k;
                    fy += (dy / dist) * diff * k;
                }
            }

            // Same-industry mild cohesion
            for (let j = 0; j < this.nodes.length; j++) {
                if (i === j) continue;
                const node2 = this.nodes[j];
                if (node2.industry !== node1.industry) continue;
                const dx = node2.x - node1.x;
                const dy = node2.y - node1.y;
                const dist = Math.sqrt(dx * dx + dy * dy) || 1;
                if (dist > 180) {
                    fx += (dx / dist) * 0.4;
                    fy += (dy / dist) * 0.4;
                }
            }

            fx += (this.width / 2 - node1.x) * 0.003;
            fy += (this.height / 2 - node1.y) * 0.003;

            node1.vx = (node1.vx + fx * 0.01) * damping;
            node1.vy = (node1.vy + fy * 0.01) * damping;

            const velocity = Math.sqrt(node1.vx * node1.vx + node1.vy * node1.vy);
            if (velocity > maxVelocity) maxVelocity = velocity;

            node1.x += node1.vx;
            node1.y += node1.vy;

            node1.x = Math.max(40, Math.min(this.width - 40, node1.x));
            node1.y = Math.max(30, Math.min(this.height - 30, node1.y));
        }

        if (maxVelocity < minVelocity && !this.draggingNode) {
            this.isStable = true;
        }
    }

    draw() {
        if (!this.ctx) return;
        this.ctx.clearRect(0, 0, this.width, this.height);

        // Edges
        this.ctx.lineCap = 'round';
        for (const edge of this.edges) {
            const isHighlight =
                this.hoveredNode &&
                (edge.fromNode === this.hoveredNode || edge.toNode === this.hoveredNode);
            const alpha = Math.min(1, edge.weight / 50);
            this.ctx.strokeStyle = isHighlight ? '#2563eb' : '#94a3b8';
            this.ctx.lineWidth = Math.max(0.6, edge.weight / 25);
            this.ctx.globalAlpha = isHighlight ? 0.9 : alpha * 0.45;
            this.ctx.beginPath();
            this.ctx.moveTo(edge.fromNode.x, edge.fromNode.y);
            this.ctx.lineTo(edge.toNode.x, edge.toNode.y);
            this.ctx.stroke();
        }
        this.ctx.globalAlpha = 1;

        // Determine which nodes should show labels:
        // - hovered node + its neighbors (from highlighted edges)
        // - selected node
        // - when nodes count is small (<=20), show all
        const labelTargets = new Set();
        if (this.nodes.length <= 20) {
            for (const n of this.nodes) labelTargets.add(n);
        }
        if (this.hoveredNode) {
            labelTargets.add(this.hoveredNode);
            for (const edge of this.edges) {
                if (edge.fromNode === this.hoveredNode) labelTargets.add(edge.toNode);
                if (edge.toNode === this.hoveredNode) labelTargets.add(edge.fromNode);
            }
        }
        if (this.selectedNode) labelTargets.add(this.selectedNode);

        // Nodes
        this.ctx.font = '600 11px -apple-system, BlinkMacSystemFont, sans-serif';
        this.ctx.textAlign = 'center';
        this.ctx.textBaseline = 'top';

        for (const node of this.nodes) {
            const isSelected = node === this.selectedNode;
            const isHovered = node === this.hoveredNode;
            const dimmed = this.hoveredNode && !labelTargets.has(node);
            const r = isHovered ? node.radius + 3 : node.radius;

            this.ctx.globalAlpha = dimmed ? 0.25 : 1;
            this.ctx.fillStyle = node.color;
            this.ctx.beginPath();
            this.ctx.arc(node.x, node.y, r, 0, Math.PI * 2);
            this.ctx.fill();

            if (isSelected || isHovered) {
                this.ctx.strokeStyle = '#fff';
                this.ctx.lineWidth = 3;
                this.ctx.stroke();
            }
        }
        this.ctx.globalAlpha = 1;

        // Labels (only for targets — avoids the "blob of text" problem)
        for (const node of labelTargets) {
            const label = (node.label || '').substring(0, 14);
            this.ctx.strokeStyle = 'rgba(255,255,255,0.95)';
            this.ctx.lineWidth = 3;
            this.ctx.strokeText(label, node.x, node.y + node.radius + 4);
            this.ctx.fillStyle = '#1f2937';
            this.ctx.fillText(label, node.x, node.y + node.radius + 4);
        }
    }

    handleMouseDown(event) {
        const rect = this.canvas.getBoundingClientRect();
        const x = event.clientX - rect.left;
        const y = event.clientY - rect.top;
        this.draggingNode = this.findNodeAt(x, y);
        this.dragDistance = 0;
        if (this.draggingNode) {
            this.isDragging = true;
            this.isStable = false;
        }
    }

    handleMouseMove(event) {
        const rect = this.canvas.getBoundingClientRect();
        const x = event.clientX - rect.left;
        const y = event.clientY - rect.top;

        if (this.isDragging && this.draggingNode) {
            this.dragDistance +=
                Math.abs(x - this.draggingNode.x) + Math.abs(y - this.draggingNode.y);
            this.draggingNode.x = x;
            this.draggingNode.y = y;
            this.draggingNode.vx = 0;
            this.draggingNode.vy = 0;
            this.tooltipVisible = false;
        } else {
            const found = this.findNodeAt(x, y);
            this.hoveredNode = found;
            this.canvas.style.cursor = found ? 'pointer' : 'default';
            if (found) {
                this.tooltipVisible = true;
                this.tooltipX = Math.min(x + 14, this.width - 260);
                this.tooltipY = Math.min(y + 14, this.height - 140);
                this.tooltipData = found;
            } else {
                this.tooltipVisible = false;
            }
        }
    }

    handleMouseLeave() {
        this.tooltipVisible = false;
        this.hoveredNode = null;
        this.isDragging = false;
        this.draggingNode = null;
    }

    handleMouseUp() {
        this.isDragging = false;
        this.draggingNode = null;
    }

    handleClick(event) {
        // Suppress click if this was really a drag
        if (this.dragDistance > 5) return;
        const rect = this.canvas.getBoundingClientRect();
        const x = event.clientX - rect.left;
        const y = event.clientY - rect.top;
        const node = this.findNodeAt(x, y);
        if (node) {
            this.selectedNode = node;
            this.navigateToRecord(node.id);
        }
    }

    findNodeAt(x, y) {
        for (const node of this.nodes) {
            const dx = x - node.x;
            const dy = y - node.y;
            if (Math.sqrt(dx * dx + dy * dy) < node.radius + 4) return node;
        }
        return null;
    }

    navigateToRecord(recordId) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId, actionName: 'view' }
        });
    }

    handleSimilarityChange(event) {
        this.minSimilarity = parseInt(event.detail.value, 10);
        this.isLoading = true;
    }

    handleNodeCountChange(event) {
        this.maxNodes = parseInt(event.detail.value, 10);
        this.isLoading = true;
    }

    disconnectedCallback() {
        if (this.animationId) cancelAnimationFrame(this.animationId);
    }

    get hasInsights() {
        return this.crossIndustryInsights.length > 0;
    }

    get statsLabel() {
        return `${this.nodes.length}件のニーズカード / ${this.edges.length}件の類似関係`;
    }

    get tooltipStyle() {
        return `left:${this.tooltipX}px; top:${this.tooltipY}px;`;
    }
}
