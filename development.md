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

## 与 Elixir 的兼容性缺口

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
