# Elixism 开发历史与开发流程

## 项目本质

**Elixism** 是一个从零构建的 **Elixir → Scheme → WebAssembly 编译器**,用 Guile 实现。目标分两条线:

- **现版编译器** `module/elixir/*.scm`:以 s-表达式作为 AST 的可工作编译器
- **自举前端** `frontend/*.ex`:用 Elixir 自己写 tokenizer/parser,采用真实 Elixir 的 `{name, meta, args}` quoted AST

运行时有两个后端:**宿主 Guile**(原生字节码)和 **Hoot/WASM**(在 Node 或 Cloudflare 边缘运行)。

---

## 开发历史(按阶段)

### 阶段一:前端引导与精度对齐

- 补齐 `a[b]` 取值的空白处理、十六进制/Unicode 字符串转义
- 开始转译真实的 `elixir_tokenizer.erl`
- 确立四点目标:① AST 迁移到 `{name, meta, args}` ② 精度对齐 `elixir_parser.yrl` ③ **新增宏展开阶段** ④ 自举

### 阶段二:宏系统(关键纠偏)

- 最初把 `quote` 实现进了**代码生成器**里 → 用户明确否决:"it is not right, remove quote/unquote implementation"
- **正确做法**:宏展开必须是独立的 **AST→AST 阶段**,参照 `elixir_expand.erl` + `elixir_quote.erl`
- 于是 `git reset --hard` 回退,重建为独立的 `expand.scm`:
  - `expand-program` / `expand-expr` 结构化遍历
  - `quote-to-ast`:quote 改写成构造数据的 AST
  - `register-macro!` / 通过 `*macro-runner*` 调用宏与 `use`→`__using__` 注入
  - alias 解析(普通 / `.{}` 分组 / `as:`),`import`/`require` 作为指令丢弃
- 管线变为:`(compile-program (expand-program (parse src)))`

### 阶段三:用 Elixism 编译真实项目

- **playground/**:用 Elixism 编译运行,实现 `@`-模块属性、宏,无需改动源码即可跑通
- **Garden**(新建 Phoenix 风格测试项目):前端 + Ecto + SQLite + LiveView + 登录注册认证
  - 用 **Node.JS 的 JS interop 替换 Bandit** 来提供 HTTP/WebSocket,但仍编译 Plug、PubSub

### 阶段四:状态持久化与真实 SQLite

- 无进程模型下用运行时 `Store`(模块级 hashtable)做持久状态
- 真实 SQLite:Node 端用 `node:sqlite`,边缘端用 **Cloudflare D1**
- **效果重放协议(effects-replay)**:同步 WASM ↔ 异步 D1 的桥接 —— handler 返回 `{"need":{sql,params}}`,宿主执行查询后把结果追加再重新调用

### 阶段五:Cloudflare 部署

- 部署 Garden 到 **elixism.sola.day**:fetch handler + Durable Objects(WebSocket hibernation)+ D1 绑定 + wrangler
- 修了 `/register` 404(原来只有 `/api/*` 路由,补了 HTML 前端)

### 阶段六:性能基准测试(JSON)

- 用 **Jason** 跑 BEAM / Guile / Hoot-WASM 三方性能对比
- 逐个补功能把 Jason 的解析往前推:`::` 运算符、alias、try/catch/else、Bitwise、`Record.defrecordp`
- 推到 **第 108 行的 `bytecase` 墙**(`Jason.Codegen.bytecase` 是编译期解码器生成器,属于范畴性阻塞)
- 加入 **Poison** 作为第四方基准
- 最新结果(µs/parse):Poison 在对象/字符串密集文件上胜过 Jason,但浮点密集的 canada.json 慢约 2×;Elixism/Guile 约为 Jason 的 8×,Elixism/Hoot-WASM 约 68×,四方节点计数一致

---

## 开发流程 / 方法论

```
源码 → lexer → parser(Scheme s-expr AST)
     → expand-program(宏展开,独立 AST→AST 阶段)
     → compile-program(AST→Scheme)
     → Guile 求值  或  Hoot→WASM
```

贯穿始终的几条工作习惯:

1. **测试常绿**:`make test` 全程保持通过(256 → 265 → 269)
2. **小步推进**:每加一个语言特性就跑真实项目/基准验证,而非一次性大改
3. **遇到宿主限制就绕**:Elixism 自身的解析限制(`when` 不能换行、guard 不接受 `X and (A or B)`、无自定义 guard 函数)都靠改写表达式规避
4. **典型踩坑**:
   - 加 `host.sql` 外部导入导致所有 WASM 宿主 LinkError → 补 `sql` 桩
   - `&&&`/`|||` 误分词 → 把 lexer operators 严格按最长优先重排
   - fish shell 不支持 `for...done` → 用 `sh -c '...'` 包裹

---

## 真实 hex 包基准(同源码跨后端对比)

`bench-graph/` 用**未改动**的真实库,在 BEAM 与 Elixism/Guile 上跑同一份源码,
带正确性门禁(两端结果必须逐字节一致):

| 基准 | 包 | 工作负载 | 慢倍数(M 芯片) |
|---|---|---|---|
| graph | libgraph | 构图 + 强连通分量 + 无环判定 + 可达 | ~46–109×(超线性,alist map) |
| decimal | Decimal | 任意精度算术(new/mult/sub/add 折叠) | ~49× |

为跑通这两个库,补了一大批通用特性(heredoc、编译期 `if`、二进制 spec、
struct alias 解析、缺省参数宏、`bind_quoted: binding()`、`for...into: do` 等),
全部进了 `make test`。详见各 README 与 git 历史。

**已知不可跑的真实库**(范畴性缺口,非小补丁):
- **Jason / Poison**:字节级二进制匹配 `<<x::binary-size(n)>>`,与 Elixism 的
  codepoint 串模型冲突(且会 O(n²) 病态慢)。
- **Earmark**:91 个 `~r` 正则 + 53 处 `Regex.` —— 需要**真正的正则引擎**(独立子系统),
  **留待将来有正则能力后再做**。
- **Decimal 的 `div`/`compare`**:依赖 `pow10` 的 0..104 基表,该表由编译期
  `Enum.reduce` 边跑边 `defp` 生成 —— 需要编译期模块体执行模型,Elixism 暂无。

---

## 宏引擎补全(支撑 Phoenix/Ecto 所需的宏功能)

> 本轮把宏子系统从「只能跑最简单的 quote/unquote」补到「能跑 Phoenix/Ecto 风格 DSL」。
> 宿主 Guile 后端;`make test` 由 269 → 279 全绿。下面的「缺口」清单中宏相关项已基本消除。

### 已实现

- **`quote` 全节点覆盖**(`expand.scm` quote-to-ast):if/case/cond/fn/for/with/try/
  match/map/map-update/struct/struct-update/n-tuple/binary/capture/dotcall/receive/
  attr/字符串插值,外加 `unquote_splicing`。
- **`ast↔term` 桥对称全覆盖**(`eval.scm`):宏可以接收并返回任意代码(do 块、case、fn…)。
- **`bind_quoted`**:`quote bind_quoted: [k: v] do … end`,按真实 `elixir_expand.erl` 语义
  脱糖为 `k = v` 前缀(非 escape)。
- **动态函数名** `def unquote(name)(args)`(parser + quote + 编译);宏返回的 def 列表
  (`for f <- … do quote do def … end end` 惯用法)被摊平为模块定义。
- **特殊形式** `__MODULE__`/`__ENV__`/`__CALLER__`/`__DIR__`,在注入上下文里解析。
- **`import` 绑定**:`import Mod` 后裸名宏调用可展开;`use` 注入的 import 影响其后的行
  (模块体按序处理,import 用可变 box 维护)。
- **`Macro` 模块**:`escape`、`expand`/`expand_once`(解析 alias)、`var`、`to_string`。
- **编译期模块属性**:`Module.register_attribute(accumulate:)` / `put_attribute` /
  `get_attribute`(共享存储在 `runtime.scm`),展开期执行并从输出剔除。
- **`@before_compile`**:模块体处理完后调用钩子的 `__before_compile__(env)`(传入真实
  `%Macro.Env{module: …}`),生成的 def 追加进模块 —— 跑通 Ecto.Schema 套路。
- **do 块宏调用** `schema "x" do … end` / 嵌套 `scope "/" do … end`,块作为 `do:` 关键字
  实参挂到调用上,走宏展开;**关键字列表形参** `def macro(name, do: block)`。
- **多子句 / 带 guard 的 defmacro**。

### 已验证的 DSL 形态(集成测试锁定)

- **Ecto.Schema**:`use` → `schema "users" do field :name, :string … end` → `@before_compile`
  读累积字段 → 生成 `__schema__(:fields)` + `defstruct`,`%User{…}` 可构造。
- **Phoenix.Router**:`use` → 嵌套 `scope "/api" do get "/users", :h end` → 路由累积。
- **Ecto.Query**:`from u in "users", where: u > 1, select: u` 宏拿到的正是
  `{:in,[],[{:u,[],nil},"users"]}` + 关键字列表,与真实 Ecto 一致。

### 模块系统补全(本轮)

- **`import` 函数绑定**:`import Mod` 后裸名可调用 Mod 的**函数**(此前只有宏)。
  运行时维护 `module-imports`(`dispatch.scm`),`ex-call-local` 找不到本地/Kernel 时
  回退到导入模块。`only:`/`except:` 解析但不强制(更宽松,跑通合法程序无碍)。
- **顶层 `alias` / `import`**:`alias Enum, as: E` 后 `E.map(...)` 可解析;顶层 import
  注册到隐式 `Elixir` 模块。
- **嵌套 `defmodule`**:`defmodule Outer do defmodule Inner do … end end` —— Inner 被提升
  到顶层并限定名为 `Outer.Inner`,Outer 内用短名 `Inner` 经 alias 解析。提升模块放在程序
  块**最前**,不影响脚本返回值。
- **`defdelegate name(args), to: M[, as: real]`**:展开为转发 def。
- **`Module.concat`/`split`/`safe_concat`、`function_exported?/3`、`apply/2,3`**。
- **修了潜在 bug**:`*macros*` 注册表跨程序泄漏 —— host 每次编译前 `reset-macros!`
  (否则前一程序的 `defmacro M.foo` 会让后一程序的同名函数调用误当宏展开)。

### 仍未做(宏/模块相关的次要项)

- 嵌套模块内的宏不被 `install-macros!` 安装(只扫顶层模块);嵌套模块**函数**正常。
- `import` 的 `only:`/`except:` 不强制过滤;无 `import` 的 `:macros`/`:functions` 选择。
- 宏卫生(hygiene)/ `var!` —— 当前变量按名字直传,非真正卫生;多数 DSL 不依赖。
- `@after_compile` / `@on_definition`;`__CALLER__` 仅给出 ctx 模块,非真实调用点 env。
- WASM bundle 仍无 macro runner(宏只在宿主展开,这与 AOT 模型一致,边缘端跑展开后的产物)。
- 插值在 `quote` 里用内部 `__istring__` 编码,非真实 `<<>>`/`Kernel.to_string` 形式
  (功能等价,但宏若内省插值结构会看到不同形状)。

---

## 与 Elixir 的兼容性缺口(历史快照,宏部分见上)

按**影响程度**从大到小。

### 一、范畴性缺口(最根本)

**1. 宏定义引擎缺失** ⭐ 最致命
- `defmacro`/`defmacrop` 只能被解析和调用(通过 `*macro-runner*`,`expand.scm:36`),但**没有编译期执行用户宏代码的引擎**。
- WASM bundle 没有 macro runner(`wasm-node/bundle.scm`)→ 边缘端完全不能用宏。
- 这是 **Jason 撞墙的真正原因**:`Jason.Codegen` 用 ~38 次宏调用 + `bytecase` 在编译期生成解码器。

**2. `quote` 只覆盖 13 种 AST 节点**
- `expand.scm:314` 直接 `(error "quote: unsupported node")`。
- 不能 quote:`if` / `case` / `cond` / `fn` / `for` / `with` / `try` / 模式 / 守卫 / 捕获 / 结构体字面量 / 二进制段。
- 没有 `unquote_splicing`、`__ENV__`、`__CALLER__`;quoted 形式丢失行号元信息。

### 二、模块系统

| 形式 | 状态 |
|---|---|
| `alias`(模块内) | ✅ 支持(含 `as:`、`.{}` 分组) |
| `alias`(顶层) | ❌ 静默丢弃 |
| `import Mod` | ❌ 解析后丢弃 —— 所以 `import Bitwise` 后 `a &&& b` 不绑定 |
| `require Mod` | ❌ 丢弃 |
| `use Mod` | ⚠️ 仅 `use GenServer` 走原生实现;其它 `__using__` 注入静默失败 |
| `@behaviour`/`@impl`/`@moduledoc` | ❌ |
| `@type`/`@spec`/`@callback` | ⚠️ 解析但 RHS 直接跳过、不检查 |

### 三、WASM 后端比宿主弱(运行期)

- **进程调度器在 WASM 里是桩**:`spawn`/`send`/`receive` 识别但运行时失败(依赖 `call-with-prompt`,Hoot 尚未编译进 WASM)。宿主 Guile 上完全正常。`DOCUMENTATION.md:303-305`
- 无文件系统、无 socket、无 `monotonic_time`、无宏。

### 四、语法层小缺口

- **Sigils**:只有 `~w ~W ~s ~c ~r`(`~r` 还只是桩);缺 `~S ~C ~U ~b ~x` 和自定义 sigil。
- **Heredoc**(`"""..."""`)完全没有。
- **非字节对齐的二进制尾**(`<<...rest::bits>>` 起点不在字节边界)未实现。
- **`foo arg do...end`** 裸调用块有意不支持,只有特殊形式接受 `do...end`。
- **必需关键字参数** `def foo(a, b:)` 不识别。
- **Range** `a..b` 直接物化成列表,无惰性、无无界范围。

### 五、标准库空缺

- **没有 `Keyword` 模块**(关键字列表只能当 tuple 列表手撸)。
- **没有 `Task` / `Agent` / `Application` / `Registry` / `ETS`**(但 `GenServer`/`Supervisor` 有原生实现)。
- `Kernel.apply/2-3` 不是公开函数;`==`/`===` 等只作为运算符存在,不能当函数传。
- `Enum` 缺惰性 `Stream`、`slice`;`String` 缺 `jaro_distance`、真正的正则。
- 无运行时自省(`Code`、`Module.get_attribute`、`__info__`)。

### 优先级建议(若目标是跑通更多真实库)

1. **宏定义引擎 + 扩大 `quote` 覆盖**(`import`/`require` 绑定一起做)—— 解锁 Jason 这类元编程重的库,影响面最大。
2. **WASM 进程调度器**(接上 Hoot 的 delimited continuation)—— 解锁边缘端真正的 OTP。
3. **`import` 绑定**(尤其 `import Bitwise`)—— 单点小改,但很多库用。
4. 语法补漏(heredoc、sigil、非对齐二进制尾)—— 零散但便宜。
