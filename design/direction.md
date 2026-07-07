<!-- SPDX-License-Identifier: Apache-2.0 -->
# Elixism 演进方向报告(2026-07-07)

对五个架构问题的分析与结论:WasmGC vs Zig、进一步优化、Hoot 依赖、
自举现状、运行时 Elixir 化、直出 WasmGC。基于当前代码状态
(325 host 测试;`zig` 分支,commit `ac2dbd0`)。

---

## 1. WASM GC vs Zig Runtime + Linear Memory

**结论:WasmGC(Scheme/Hoot)做骨架,Zig 线性内存只做计算内核。不用 Zig
重写 runtime。**

决定性因素是 **GC**:Elixir 是不可变数据 + 海量短命分配的语言。

- WasmGC 路线:对象是引擎管理的 GC struct/array,V8/workerd 分代 GC
  免费回收。Hoot 已把 Scheme record/vector 编译到 WasmGC。
- Zig 路线:Zig 0.16 **没有 WasmGC 后端**,只有 wasm32 线性内存。得手写
  GC(zig-rt 目前是不回收的 bump heap,长驻服务必然 OOM),且对象对引擎
  不透明——跨边界只能传整数 handle,每个值都要编解码(正则内核只能走
  `(ref string)` 一进一出、数值参数触发 "illegal cast" 正是这个原因)。

性能上真相是**算法 > 语言**:map 从 alist 换 HAMT 得到 ~4680× 加速,是在
Scheme 里实现的。Zig 重写只能榨常数因子,代价却是 GC + ABI + 互操作全部重做。

| 部分 | 选型 | 理由 |
|---|---|---|
| 值模型(map/tuple/list/struct) | WasmGC (Scheme/Hoot) | 引擎 GC + 零互操作成本 |
| 编译器、dispatch、stdlib 编排 | Scheme | 与编译器同源 |
| 高阶 `Enum.*`(持闭包) | Scheme | Zig 回调 Hoot 闭包很痛 |
| 正则 / JSON-parse / bignum / 哈希 | Zig 线性内存内核 | 边界少、计算密、无需 GC |

反转条件:出现成熟的**真 WasmGC 后端语言**(MoonBit、Kotlin/Wasm 等)——
那也是 WasmGC 路线内换语言,不是退回线性内存。

## 2. 进一步优化:大头在 dispatch,不在 codegen

`compiler.scm` 的 call site 已分两级:AOT 已知目标走 `direct-call`,
未知落 `ex-call-local/remote`(hashtable 查找)。

**2026-07-07 已实施并实测**(全部验证:host 331 测试 + wasm 54 检查绿):

1. **闭世界 devirtualization —— 实测 5.1×**(`module/elixir/optimize.scm`)。
   bundle 把 corelib+程序合并为单编译单元(跨单元调用共享 fn-table 直接
   direct-call),再把剩余 `ex-call-remote/local` 改写为"惰性缓存 cell +
   装载后 `%devirt-freeze!` 一次解析";未命中回退原 dispatch,装载期语义
   字节级不变。dispatch 密集基准 15.4µs→3.0µs/iter。JSON parse 持平
   (其热循环本就 direct + Scan intrinsics)——收益属于调 builtin 的业务代码。
   `ELIXISM_NO_DEVIRT=1` 关闭。协议派发特化尚未做(热路径暂不走协议)。
2. **模式匹配决策树 —— 实测后延后**。10-clause vs 1-clause 基准:132 vs
   114ns/iter,线性匹配仅 ~3ns/clause——Hoot 的 contification 已把
   next-thunk 变成跳转,thunk 分配根本不存在。92-clause 的自举 tokenizer
   才值得做 literal 派发表;触发条件:frontend switchover。
3. **AST 层常量折叠 —— 已实施**(`fold-ast`,expand 与 compile 之间)。
   整数/浮点算术、字符串 `<>`、一元 `-`/`not`;`/0` 留给运行时;quote 子树
   不动。`1 + 2 * 3` 直接编成字面量 `7`。
4. **小对象表示 —— tuple 实测 1.65×**。tuple 从"record 包 vector"改为
   裸 vector(runtime.scm 12 行):一次分配一步间接,tuple 密集基准
   1070→650ns/iter。可行前提:值模型中无其他裸 vector(HAMT 节点封在
   emap record 内)。atom intern **放弃**:Hoot symbol 已是驻留 ref,
   `eq?` 即指针比较,整数索引无收益。
5. **wasm 产物 —— 已实施**。`-O3 --converge --strip-debug
   --strip-producers`(`ELIXISM_DEBUG=1` 保留 names):wasm-node
   2.22→1.97MB(−11%);elixism-worker 此前未接 wasm-opt,2.2→**1.4MB
   (−36%)**,workerd 冒烟全通。

方法论教训:每项优化先做 A/B 微基准——JSON 基准证明 devirt 对已 direct
的代码无效、决策树基准证明 thunk 早被 contify——**测过再投入**。

## 3. 当前对 Hoot 的依赖

| 依赖 | 内容 | 摆脱难度 |
|---|---|---|
| 编译器后端 | `guild compile-wasm`:CPS、尾调用、exnref、delimited continuation | 极难(见 §6) |
| JS 反射运行时 | `reflect.js`/`reflect.wasm`/`wtf8.wasm` | 中等,handler 模式可裁剪 |
| 语言方言 | bundle.scm 的 SRFI shim,限于 Hoot 的 `(guile)` 子集 | 已很薄 |

关键认识:**elixism 只把 Hoot 当 "Scheme→WasmGC 的 LLVM" 用**。前端
(~3200 行 lexer/parser/expand/compiler)、值模型、dispatch 全是自己的,
产物是纯 Scheme。Hoot 是可替换后端,不是地基。

## 4. 自举现状:前端已写出并验证,但未接管流水线

**已完成(Phase A,2026-06-06)**:`frontend/tokenizer.ex`(511 行)+
`frontend/parser.ex`(583 行),纯 Elixir、跑在 Elixism 上,输出真 Elixir
的 `{name, meta, args}` quoted AST;`check_all.sh`/`check_ast.sh` 与 BEAM
真编译器逐字节 diff,corpus 全绿。

**未完成:switchover**。生产流水线仍走 `lexer.scm`/`parser.scm`。卡在:

1. **AST 方言不同**(最大障碍):frontend 输出 quoted tuple;`expand.scm`/
   `compiler.scm` 消费 s-expr AST。要么写 quoted→s-expr 桥,要么把
   expand/compile 移到 quoted AST 上(后者才是真目标——宏展开本该在
   quoted AST 上做)。
2. **覆盖面未过自应用关**:corpus 是定向样本;还没证明能 parse 全 corelib
   与 parser.ex 自己;插值/sigil/heredoc、terminator 校验在 roadmap 里。
3. **性能垫底未就绪**:parser.ex 跑在 Elixism 动态 dispatch 上,比原生
   Scheme parser 慢——需 §2/§5 的优化先落地,切换才不是倒退。
4. expand(804 行)/compile(1005 行)仍是 Scheme,单切 parser 收益有限。

## 5. 优化器:插在 expand 和 compile 之间

```
lex → parse → expand → [optimize: s-expr→s-expr pass 管线] → compile → Scheme
```

expand 后的 AST 是普通 Scheme 数据,每个 pass 就是一次 pattern-match 遍历。
优先级:① 闭世界 devirtualize + 协议特化;② 常量折叠;③ 管道/Enum 融合
(`|> Enum.map |> Enum.filter` 重写成单遍);④ 死 clause 消除。每个 pass
独立开关,325 测试开/关各跑一遍验证语义不变。优化 pass 用 Elixir 写、
处理 quoted AST,与写宏同一手感——天然是自举第一站。

## 6. 运行时能否只用 Elixir 实现?

**大部分可以,但有不可约的 Scheme 内核。**

| 层 | 能否纯 Elixir |
|---|---|
| corelib、`Enum`/`Map`/`String` 高层逻辑 | ✅ 应该——官方 `Enum`/`Keyword`/`Access` 本就是 Elixir 写的 |
| `Jason`/JSON、Kernel 派生函数 | ✅ 大部分可下放(性能敏感的留 native) |
| 值表示、dispatch、模式匹配原语、异常、receive 调度 | ❌ 编译目标语义本身,不能用被编译语言定义(如 BEAM 之于 Erlang) |
| Zig 内核 | 保持 Zig |

目标形态:Scheme 收缩为几百行原语层,标准库整体上翻 Elixir,编译器自举——
Scheme 之于 elixism 如 C 之于 Erlang。

## 7. 能否直出 Elixir→WasmGC(甩掉 Hoot)?

可以,但先算清 Hoot 替我们干的活(实测本机 Hoot 源码):

| 层 | 规模 | 直出时谁做 |
|---|---|---|
| Wasm 工具链(`module/wasm/`:汇编/链接/验证/解释器) | ~11,900 行 | ✅ 可直接复用(独立库,不绑 Scheme 语义) |
| CPS→Wasm 后端(`backend.scm`) | ~2,900 行 | ❌ 重写 |
| 优化中端(在 **Guile** 里:peval、contification、闭包优化、DCE) | 十几年积累 | ❌ 重写——最被低估的一块 |
| WasmGC 运行时库(`stdlib.scm`:字符串/bignum/hashtable/异常的 GC 表示) | ~5,000 行 | ❌ 重写,值表示全套自设计 |

现在不做的理由:Elixir→Scheme 映射"顺纹理"(不可变、尾调用、闭包、
异常、continuation 全原生),中间层损耗主要是动态 dispatch——AST pass
就能消,不用换后端;emit 的 Scheme 免费搭 Guile 优化器的车;host 测试
路线(stock Guile 跑 325 测试、host 宏求值)依赖同一份 Scheme 产物。

将来若做:复用 Hoot 的 `(wasm …)` 汇编层 + 自定义贴 Elixir 语义的中端 IR
(决策树、直接调用、协议表)+ 先抄 Hoot 的 WasmGC 值布局(两后端可对拍)。
**触发条件**:优化 pass 落地后 profile 显示瓶颈在 Hoot 无法消除的 Scheme
通用开销且占比可观。在证据出现前,自建后端是用 20k+ 行解决未证明存在的问题。

## 建议路线

```
① AST 优化 pass(devirtualize + 决策树 + Enum 融合)   ← 收益立即兑现
② 核心库逐模块 Elixir 化(优化器抵消性能回退)
③ frontend 过自应用关 → switchover,lexer/parser.scm 退役为 stage0
④ (仅当 profile 给出证据)自研 WasmGC 后端,复用 Hoot wasm 汇编层
```

每一步投入不作废:①的优化器和 IR 正是④的前半段;②③使编译器本身成为
最大的 dogfooding 测试集。
