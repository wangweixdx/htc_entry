---
name: soc-dev
description: 通用硬件SOC架构设计、C Model、SystemVerilog RTL、功能验证 — 适用于任何SOC项目的全流程开发
---

# 通用硬件SOC开发 Skill (User Level)

跨项目使用的硬件SOC开发方法论。涵盖架构文档、C参考模型、SystemVerilog RTL、UVM验证。

## 触发条件

当用户提及以下任一关键词时自动启用：
- SOC架构、硬件架构、芯片架构、ASIC架构
- cmodel、c model、C参考模型
- RTL、SystemVerilog、SV、Verilog
- 功能验证、UVM、testbench、scoreboard
- 寄存器定义、regmap、地址映射
- NoC、AXI、AHB、APB、PCIe
- SMMU、IOMMU、MMU、地址翻译
- 中断、MSI-X、GIC、NVIC
- SR-IOV、VF、PF、虚拟化
- MIG、分区、QoS、带宽控制

## 1. 架构文档编写指南

### 文档金字塔
```
SOC-Level Spec (顶层架构)
  ├── Subsystem Spec (GPU/NPU/ISP/Video/DDR子系统)
  │   ├── Module Spec (TBU/TCU/NoC Router/DDR Controller)
  │   │   └── Register Spec (CSR/MMIO定义)
  │   └── Interface Spec (AXI/APB/PCIe/NVLink协议)
  └── Integration Spec (顶层互联、时钟、复位、电源)
```

### 架构文档必含章节
1. **设计目标** — 关键指标表格 (频率/带宽/面积/功耗/最大实例数)
2. **顶层框图** — ASCII Art 展示模块互联
3. **地址映射** — 物理地址 → 模块 → 寄存器
4. **数据流** — 关键路径上的事务生命周期
5. **异常处理** — 错误分类 + 检测点 + 恢复策略
6. **性能估算** — 延迟/带宽的理论峰值和预期效率
7. **软件接口** — 驱动/SDK 视角的寄存器/中断/DMA接口

### 推荐工具链
- 架构框图: ASCII Art / wavedrom / draw.io
- 寄存器文档: SystemRDL → 自动生成 .h / .sv / .md
- 地址映射: 电子表格 → 脚本生成 .h / linker script
- 版本管理: Markdown + git，禁止 Word/PDF 作为单一源

## 2. C Model (cmodel) 编写指南

### 设计目标
C Model 是 RTL 的黄金参考模型，用于:
- 架构探索与性能评估 (TLM/SystemC optional)
- RTL co-simulation 参考值
- 固件/驱动开发前的软件仿真

### 最小 cmodel 结构
```
cmodel/
├── include/
│   ├── types.h          # uint64_t, addr_t, sid_t...
│   ├── reg_map.h        # 寄存器定义 (generated from SystemRDL)
│   └── config.h         # 编译参数 (NUM_VF, HBM_SIZE, ...)
├── src/
│   ├── [module].c/h     # 每个硬件模块一个 .c/.h
│   └── top.c/h          # SOC 顶层 (实例化所有模块 + 互联)
├── test/
│   ├── test_harness.c   # 测试框架 main()
│   └── tests/           # 每个场景一个 .c
├── scripts/
│   └── reg_gen.py       # SystemRDL → reg_map.h 生成脚本
└── Makefile
```

### 编码约定
```c
// 命名: 模块前缀 + 函数名
uint64_t tbu_translate(tbu_t *tbu, uint16_t sid, uint64_t va, int *err);
void     tcu_page_walk(tcu_t *tcu, uint64_t ipa, pte_t *pte);
void     gpu_exec_cmd(gpu_t *gpu, cmd_t *cmd, result_t *result);

// 错误处理: 统一返回码
typedef enum {
    ERR_NONE = 0,
    ERR_PAGE_FAULT,
    ERR_ACCESS_DENIED,
    ERR_SID_INVALID,
    ERR_MIG_PARTITION_VIOLATION,
} err_code_t;

// 事务建模
typedef struct {
    uint64_t addr;
    uint32_t data[4];      // max 16-byte burst
    uint8_t  len;           // bytes
    uint16_t sid;
    uint32_t pasid;
    bool     is_write;
    uint64_t timestamp_ns;  // for performance model
} axi_xact_t;
```

### 验证 cmodel 自身正确性
- 单元测试每个模块 (如 TBU 的 TLB 命中/未命中/替换策略)
- 回归测试每次提交自动运行
- C Model vs C Model 双实现交叉验证 (独立开发者)

## 3. SystemVerilog RTL 编码指南

### 目录约定
```
rtl/
├── [module_name]/
│   ├── [module_name]_top.sv    # 模块顶层，实例化子模块
│   ├── [sub_module].sv         # 子模块
│   └── [module_name]_pkg.sv    # 参数/类型/函数包
├── include/
│   ├── [chip]_pkg.sv           # 全局参数 (CHIP_NAME, NUM_CORES...)
│   └── axi_typedef.sv          # AXI 类型定义
└── scripts/
    └── filelist_gen.py         # 生成 filelist.f
```

### RTL 编码规则

**综合友好:**
```systemverilog
// 所有数组、寄存器声明带初值 (仅仿真，综合工具忽略)
logic [31:0] counter = '0; // 注意: ASIC 综合不可依赖初始值！

// FSM 使用 enum + 显式复位值
typedef enum logic [2:0] {
    ST_IDLE    = 3'b001,  // one-hot recommended for timing
    ST_ACTIVE  = 3'b010,
    ST_DONE    = 3'b100
} state_t;
```

**参数化:**
```systemverilog
module fifo_sync #(
    parameter int WIDTH   = 32,
    parameter int DEPTH   = 16,
    parameter bit USE_SRAM = 1   // 1: SRAM macro, 0: Register
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             wr_en,
    input  logic [WIDTH-1:0] wr_data,
    output logic             full,
    input  logic             rd_en,
    output logic [WIDTH-1:0] rd_data,
    output logic             empty
);
```

**跨时钟域:**
```systemverilog
// 单 bit: 2-FF synchronizer
logic [1:0] sync_ff;
always_ff @(posedge dst_clk) sync_ff <= {sync_ff[0], src_signal};
assign dst_signal = sync_ff[1];

// 多 bit: Async FIFO (使用 DC FIFO IP)
// bus: AXI/AHB bridge (使用 AXI Clock Converter IP)
```

**断言:**
```systemverilog
// 基本安全断言
assert property (@(posedge clk) disable iff (!rst_n)
    !(wr_en && rd_en && full && empty));  // FIFO overflow/underflow

assert property (@(posedge clk) disable iff (!rst_n)
    dma_valid |-> ##1 $stable(dma_addr));  // 地址在事务期间不变
```

### 禁止使用的语法
- `initial` 块 (ASIC 综合不支持)
- `#delay` (不可综合)
- `fork/join` (不可综合)
- `$random` / `$display` (仅用于 testbench)
- 组合逻辑中的锁存器 (latch inference)
- 不可综合的 `for` 循环

## 4. 功能验证指南

### 验证策略
```
┌────────────────────────────────────────────┐
│         验证方法论 (V-Model)                 │
│                                            │
│  Spec ────────────────────────── SOC Test  │
│   │                                    │   │
│  Architecture ────────── Subsystem Test │   │
│   │                                    │   │
│  Micro-Architecture ─────── IP Test     │   │
│                                            │
│  C Model ── co-sim ── RTL ── Gate-Level  │
└────────────────────────────────────────────┘
```

### UVM 环境模板
```systemverilog
// test_base.sv
class test_base extends uvm_test;
    `uvm_component_utils(test_base)

    gpu_soc_env  env;
    virtual_if   vif;  // 连接 RTL 的 virtual interface

    function void build_phase(uvm_phase phase);
        env = gpu_soc_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        // 运行 sequence
        phase.drop_objection(this);
    endtask
endclass
```

### 关键验证度量
| 度量 | 目标 | 检查工具 |
|------|------|---------|
| Line Coverage | ≥ 95% | vcs -cm line |
| Toggle Coverage | ≥ 90% | vcs -cm toggle |
| FSM Coverage | 100% | vcs -cm fsm |
| Functional Coverage | 100% bin hit | vcs -cm assert |
| Code Coverage Exclusion | 仅排除已验证不可达的代码 | Code review |
| C/RTL co-sim 一致性 | 全部随机种子通过 | diff + checker |

### 覆盖率驱动的验证流程
```
1. 定义覆盖率模型 (covergroup/coverpoint)
2. 初始随机测试 (100K seeds)
3. 收集覆盖率 → 分析空洞 (coverage hole)
4. 编写定向测试填补空洞
5. 重复 2-4 直到达标
6. 最终回归 (1M seeds)
```

## 5. 工具链推荐

| 环节 | 工具 | 用途 |
|------|------|------|
| 架构图 | wavedrom / draw.io | 时序图、框图 |
| 寄存器 | SystemRDL Compiler | 寄存器规范 → .h/.sv |
| C Model | GCC/Clang + Makefile | 参考模型编译运行 |
| RTL Lint | Spyglass / Verible | 代码规范检查 |
| RTL Sim | VCS / Xcelium / Verilator | 功能仿真 |
| UVM | UVM-1.2 / UVM-2017 | 验证框架 |
| Coverage | VCS URG / Verdi | 覆盖率合并分析 |
| Waveform | Verdi / GTKWave | 波形调试 |
| Formal | JasperGold / VC Formal | 形式验证 |
| CDC | Meridian / Spyglass CDC | 跨时钟域检查 |
| Synthesis | Design Compiler / Genus | 逻辑综合 |
