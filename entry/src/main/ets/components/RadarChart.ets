/**
 * RadarChart - 知识薄弱点雷达图组件
 */
export class RadarData {
  dimensions: string[] = [];
  current: number[] = [];
  target: number[] = [];
  weakIndices: number[] = [];
  strengthIndices: number[] = [];

  constructor(dims: string[], cur: number[], tgt: number[], weak: number[], strong: number[]) {
    this.dimensions = dims;
    this.current = cur;
    this.target = tgt;
    this.weakIndices = weak;
    this.strengthIndices = strong;
  }
}

@Component
export struct RadarChart {
  @Prop dimensions: string[] = [];
  @Prop current: number[] = [];
  @Prop target: number[] = [];
  @Prop weakIndices: number[] = [];
  @Prop strengthIndices: number[] = [];
  @State canvasWidth: number = 420;
  @State canvasHeight: number = 420;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  build() {
    Canvas(this.ctx)
      .width(this.canvasWidth)
      .height(this.canvasHeight)
      .onReady(() => this.drawChart())
  }

  private drawChart(): void {
    const ctx: CanvasRenderingContext2D = this.ctx;
    const cx: number = this.canvasWidth / 2;
    const cy: number = this.canvasHeight / 2;
    const radius: number = Math.min(cx, cy) * 0.30;
    const dims: string[] = this.dimensions;
    const n: number = dims.length > 0 ? dims.length : 5;
    const levels: number = 5;

    ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);

    // 1. 背景网格
    for (let level: number = 1; level <= levels; level++) {
      const r: number = radius * level / levels;
      ctx.beginPath();
      for (let i: number = 0; i < n; i++) {
        const angle: number = (Math.PI * 2 / n) * i - Math.PI / 2;
        const x: number = cx + r * Math.cos(angle);
        const y: number = cy + r * Math.sin(angle);
        if (i === 0) { ctx.moveTo(x, y); }
        else { ctx.lineTo(x, y); }
      }
      ctx.closePath();
      ctx.strokeStyle = '#E2E8F0';
      ctx.lineWidth = 0.5;
      ctx.stroke();
    }

    // 2. 轴线
    for (let i: number = 0; i < n; i++) {
      const angle: number = (Math.PI * 2 / n) * i - Math.PI / 2;
      ctx.beginPath();
      ctx.moveTo(cx, cy);
      ctx.lineTo(cx + radius * Math.cos(angle), cy + radius * Math.sin(angle));
      ctx.strokeStyle = '#E2E8F0';
      ctx.lineWidth = 0.5;
      ctx.stroke();
    }

    // 3. 目标水平 (灰虚线)
    if (this.target.length === n) {
      ctx.beginPath();
      for (let i: number = 0; i < n; i++) {
        const angle: number = (Math.PI * 2 / n) * i - Math.PI / 2;
        const val: number = Math.max(0.05, Math.min(1, (this.target[i] || 70) / 100));
        const r: number = radius * val;
        if (i === 0) { ctx.moveTo(cx + r * Math.cos(angle), cy + r * Math.sin(angle)); }
        else { ctx.lineTo(cx + r * Math.cos(angle), cy + r * Math.sin(angle)); }
      }
      ctx.closePath();
      ctx.strokeStyle = '#94A3B8';
      ctx.lineWidth = 1.5;
      ctx.setLineDash([6, 4]);
      ctx.stroke();
      ctx.setLineDash([]);
    }

    // 4. 当前水平 (蓝绿半透明填充)
    if (this.current.length === n) {
      ctx.beginPath();
      for (let i: number = 0; i < n; i++) {
        const angle: number = (Math.PI * 2 / n) * i - Math.PI / 2;
        const val: number = Math.max(0.02, Math.min(1, (this.current[i] || 50) / 100));
        const r: number = radius * val;
        if (i === 0) { ctx.moveTo(cx + r * Math.cos(angle), cy + r * Math.sin(angle)); }
        else { ctx.lineTo(cx + r * Math.cos(angle), cy + r * Math.sin(angle)); }
      }
      ctx.closePath();
      ctx.fillStyle = 'rgba(37, 99, 235, 0.2)';
      ctx.fill();
      ctx.strokeStyle = '#2563EB';
      ctx.lineWidth = 2;
      ctx.stroke();
    }

    // 5. 标注 + 标记点
    ctx.font = '40px sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';

    for (let i: number = 0; i < n; i++) {
      const angle: number = (Math.PI * 2 / n) * i - Math.PI / 2;
      const labelR: number = radius + 68;
      const labelX: number = cx + labelR * Math.cos(angle);
      const labelY: number = cy + labelR * Math.sin(angle);

      // 维度标签
      const label: string = dims[i] || '';
      ctx.fillStyle = '#334155';
      ctx.fillText(label, labelX, labelY);

      // 数据点
      const curVal: number = this.current.length === n ? (this.current[i] || 50) : 50;
      const pointVal: number = Math.max(0.02, Math.min(1, curVal / 100));
      const pointR: number = radius * pointVal;
      const pointX: number = cx + pointR * Math.cos(angle);
      const pointY: number = cy + pointR * Math.sin(angle);

      if (this.isWeak(i)) {
        ctx.beginPath();
        ctx.arc(pointX, pointY, 7, 0, Math.PI * 2);
        ctx.fillStyle = '#EF4444';
        ctx.fill();
        ctx.strokeStyle = '#FFFFFF';
        ctx.lineWidth = 2;
        ctx.stroke();
      } else if (this.isStrength(i)) {
        ctx.beginPath();
        ctx.arc(pointX, pointY, 5, 0, Math.PI * 2);
        ctx.fillStyle = '#2563EB';
        ctx.fill();
      } else {
        ctx.beginPath();
        ctx.arc(pointX, pointY, 5, 0, Math.PI * 2);
        ctx.fillStyle = '#3B82F6';
        ctx.fill();
      }
    }
  }

  private isWeak(index: number): boolean {
    for (let i: number = 0; i < this.weakIndices.length; i++) {
      if (this.weakIndices[i] === index) { return true; }
    }
    return false;
  }

  private isStrength(index: number): boolean {
    for (let i: number = 0; i < this.strengthIndices.length; i++) {
      if (this.strengthIndices[i] === index) { return true; }
    }
    return false;
  }
}
