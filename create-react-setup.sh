#!/usr/bin/env bash
# Usage: ./create-react-setup.sh <project-name> [--pm bun|pnpm] [--shadcn]
set -euo pipefail

NAME="${1:?Usage: ./create-react-setup.sh <project-name> [--pm bun|pnpm] [--shadcn]}"
shift
PM="" SHADCN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pm) PM="$2"; shift 2 ;;
    --shadcn) SHADCN=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PM" ]]; then
  read -rp "Package manager (bun/pnpm) [pnpm]: " PM
  PM="${PM:-pnpm}"
fi

case "$PM" in
  bun)  ADD="bun add";  ADD_DEV="bun add -d";  X="bunx";      CREATE="bun create vite@latest" ;;
  pnpm) ADD="pnpm add"; ADD_DEV="pnpm add -D"; X="pnpm dlx";  CREATE="pnpm create vite@latest" ;;
  *) echo "Invalid --pm '$PM' (bun or pnpm)" >&2; exit 1 ;;
esac
command -v "$PM" >/dev/null || { echo "$PM not installed" >&2; exit 1; }

# ---------- 1. Vite (latest) ----------
$CREATE "$NAME" --template react-ts
cd "$NAME"

# ---------- 2. Dependencies ----------
$ADD @tanstack/react-router @tanstack/react-query zustand zod
$ADD_DEV @tanstack/router-plugin @tanstack/router-cli \
  @tanstack/react-router-devtools @tanstack/react-query-devtools \
  tailwindcss @tailwindcss/vite @types/node

# ---------- 3. vite.config.ts ----------
cat > vite.config.ts <<'EOF'
import path from 'node:path';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import { tanstackRouter } from '@tanstack/router-plugin/vite';

export default defineConfig({
  plugins: [
    tanstackRouter({
      target: 'react',
      autoCodeSplitting: true,
      routesDirectory: './src/pages',
      generatedRouteTree: './src/routeTree.gen.ts',
      routeToken: 'layout',
      indexToken: 'page',
      routeFileIgnorePrefix: '-',
      routeFileIgnorePattern:
        '(^|/)(components|hooks|utils|stores|store|queries|mutations|schemas|api|mocks|types|constants|context|contexts|lib|tests|__tests__|stories)(/|$)|(^|/)(components|hooks|utils|stores|queries|mutations|schemas|api|mocks|types|constants|contexts|lib)\\.(ts|tsx)$|\\.test\\.(ts|tsx)$|\\.spec\\.(ts|tsx)$|\\.stories\\.(ts|tsx)$'
    }),
    react(),
    tailwindcss()
  ],
  resolve: {
    alias: { '@': path.resolve(__dirname, './src') }
  },
  server: { port: 3000 }
});
EOF

# ---------- 4. tsconfig paths ----------
node - <<'EOF'
const fs = require('fs');
for (const f of ['tsconfig.json', 'tsconfig.app.json']) {
  if (!fs.existsSync(f)) continue;
  const raw = fs.readFileSync(f, 'utf8');
  // tsconfig is JSONC: strip /* */ and // comments (no URLs in tsconfig) + trailing commas
  const stripped = raw
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|\s)\/\/.*$/gm, '$1')
    .replace(/,(\s*[}\]])/g, '$1');
  const json = JSON.parse(stripped);
  json.compilerOptions = json.compilerOptions || {};
  json.compilerOptions.paths = { '@/*': ['./src/*'] };
  fs.writeFileSync(f, JSON.stringify(json, null, 2));
}
EOF

# ---------- 5. Directory structure ----------
mkdir -p src/pages src/components/ui src/components/layout src/hooks \
  src/stores src/contexts src/lib src/utils src/constants src/styles \
  src/assets src/config
rm -f src/App.tsx src/App.css src/index.css src/assets/react.svg public/vite.svg

# ---------- 6. Styles (Tailwind v4 + theme tokens) ----------
cat > src/styles/index.css <<'EOF'
@import 'tailwindcss';

@custom-variant dark (&:where(.dark, .dark *));

:root {
  --background: oklch(1 0 0);
  --foreground: oklch(0.145 0 0);
  --border: oklch(0.922 0 0);
  --primary: oklch(0.205 0 0);
  --primary-foreground: oklch(0.985 0 0);
  --muted: oklch(0.97 0 0);
  --muted-foreground: oklch(0.556 0 0);
}

.dark {
  --background: oklch(0.145 0 0);
  --foreground: oklch(0.985 0 0);
  --border: oklch(1 0 0 / 10%);
  --primary: oklch(0.985 0 0);
  --primary-foreground: oklch(0.205 0 0);
  --muted: oklch(0.269 0 0);
  --muted-foreground: oklch(0.708 0 0);
}

@theme inline {
  --color-background: var(--background);
  --color-foreground: var(--foreground);
  --color-border: var(--border);
  --color-primary: var(--primary);
  --color-primary-foreground: var(--primary-foreground);
  --color-muted: var(--muted);
  --color-muted-foreground: var(--muted-foreground);
}

body {
  @apply bg-background text-foreground;
}
EOF

# ---------- 7. lib ----------
cat > src/lib/utils.ts <<'EOF'
import { clsx, type ClassValue } from 'clsx';
import { twMerge } from 'tailwind-merge';

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}
EOF
$ADD clsx tailwind-merge

cat > src/lib/queryClient.ts <<'EOF'
import { QueryClient } from '@tanstack/react-query';

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: { staleTime: 60_000, retry: 1 }
  }
});
EOF

# ---------- 8. Config dir (creds via env) ----------
cat > src/config/env.ts <<'EOF'
import { z } from 'zod';

const envSchema = z.object({
  VITE_API_BASE_URL: z.string().url().default('http://localhost:8000'),
  VITE_API_KEY: z.string().optional()
});

export const env = envSchema.parse(import.meta.env);
EOF

cat > .env.example <<'EOF'
VITE_API_BASE_URL=http://localhost:8000
VITE_API_KEY=
EOF
cp .env.example .env
grep -q '^\.env$' .gitignore || echo '.env' >> .gitignore

# ---------- 9. API helper ----------
cat > src/utils/api.ts <<'EOF'
import { env } from '@/config/env';

export async function callApi<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${env.VITE_API_BASE_URL}${path}`, {
    headers: {
      'Content-Type': 'application/json',
      ...(env.VITE_API_KEY ? { Authorization: `Bearer ${env.VITE_API_KEY}` } : {}),
      ...init?.headers
    },
    ...init
  });
  if (!res.ok) throw new Error(`API ${res.status}: ${res.statusText}`);
  return res.json() as Promise<T>;
}
EOF

# ---------- 10. Theme store (zustand, persisted) ----------
cat > src/stores/themeStore.ts <<'EOF'
import { create } from 'zustand';
import { persist } from 'zustand/middleware';

type Theme = 'light' | 'dark' | 'system';

interface ThemeState {
  theme: Theme;
  setTheme: (theme: Theme) => void;
}

function applyTheme(theme: Theme) {
  const dark =
    theme === 'dark' ||
    (theme === 'system' && window.matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.classList.toggle('dark', dark);
}

export const useThemeStore = create<ThemeState>()(
  persist(
    (set) => ({
      theme: 'system',
      setTheme: (theme) => {
        applyTheme(theme);
        set({ theme });
      }
    }),
    {
      name: 'theme',
      onRehydrateStorage: () => (state) => {
        if (state) applyTheme(state.theme);
      }
    }
  )
);
EOF

cat > src/components/layout/ThemeToggle.tsx <<'EOF'
import { useThemeStore } from '@/stores/themeStore';

export function ThemeToggle() {
  const { theme, setTheme } = useThemeStore();
  return (
    <button
      aria-label="Toggle theme"
      className="rounded-md border border-border px-3 py-1.5 text-sm"
      onClick={() => setTheme(theme === 'dark' ? 'light' : 'dark')}
    >
      {theme === 'dark' ? 'Light' : 'Dark'}
    </button>
  );
}
EOF

# ---------- 12. Root layout + index page ----------
cat > src/pages/__root.tsx <<'EOF'
import { Outlet, createRootRouteWithContext } from '@tanstack/react-router';
import type { QueryClient } from '@tanstack/react-query';
import { ThemeToggle } from '@/components/layout/ThemeToggle';

interface RouterContext {
  queryClient: QueryClient;
}

export const Route = createRootRouteWithContext<RouterContext>()({
  component: RootLayout
});

function RootLayout() {
  return (
    <div className="min-h-screen">
      <header className="flex items-center justify-between border-b border-border px-6 py-3">
        <span className="text-sm font-medium">App</span>
        <ThemeToggle />
      </header>
      <Outlet />
    </div>
  );
}
EOF

cat > src/pages/page.tsx <<'EOF'
import { createFileRoute } from '@tanstack/react-router';

export const Route = createFileRoute('/')({
  component: HomePage
});

function HomePage() {
  return (
    <main className="p-6">
      <h1 className="text-2xl font-bold tracking-tight">Home</h1>
      <p className="text-sm text-muted-foreground">Vite + React + TanStack ready.</p>
    </main>
  );
}
EOF

# ---------- 13. main.tsx ----------
cat > src/main.tsx <<'EOF'
import { StrictMode } from 'react';
import { createRoot, hydrateRoot } from 'react-dom/client';
import { RouterProvider, createRouter } from '@tanstack/react-router';
import './styles/index.css';
// Import the generated route tree
import { routeTree } from '@/routeTree.gen';
import { QueryClientProvider } from '@tanstack/react-query';
import { queryClient } from '@/lib/queryClient';

// Create a new router instance
const router = createRouter({ routeTree, context: { queryClient }, defaultPreload: 'intent' });

// Register the router instance for type safety
declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router;
  }
}

// Render the app — hydrate when the page was prerendered at build time
const rootElement = document.getElementById('root')!;
const app = (
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  </StrictMode>
);
if (rootElement.innerHTML) {
  // let loaders finish so the first client render matches the static HTML
  router.load().then(() => hydrateRoot(rootElement, app));
} else {
  createRoot(rootElement).render(app);
}
EOF

# ---------- 14. Optional shadcn ----------
if $SHADCN; then
  $X shadcn@latest init -y -b neutral --css-variables || \
    echo "shadcn init failed — run '$X shadcn@latest init' manually"
  $X shadcn@latest add button -y || true
fi

# ---------- 15. gen:routes script + first generate ----------
node -e "
const p = require('./package.json');
p.scripts['gen:routes'] = 'tsr generate';
require('fs').writeFileSync('package.json', JSON.stringify(p, null, 2));
"

cat > tsr.config.json <<'EOF'
{
  "routesDirectory": "./src/pages",
  "generatedRouteTree": "./src/routeTree.gen.ts",
  "routeToken": "layout",
  "indexToken": "page",
  "routeFileIgnorePrefix": "-",
  "routeFileIgnorePattern": "(^|/)(components|hooks|utils|stores|store|queries|mutations|schemas|api|mocks|types|constants|context|contexts|lib|tests|__tests__|stories)(/|$)|(^|/)(components|hooks|utils|stores|queries|mutations|schemas|api|mocks|types|constants|contexts|lib)\\.(ts|tsx)$|\\.test\\.(ts|tsx)$|\\.spec\\.(ts|tsx)$|\\.stories\\.(ts|tsx)$"
}
EOF
$PM run gen:routes

# ---------- 16. AGENTS.md ----------
cat > AGENTS.md <<'EOF'
# AGENTS.md

Guidance for AI agents working on this TypeScript codebase.

## Project Overview

Vite + React 19 + TypeScript frontend. File-based routing via TanStack Router.
State via Zustand + TanStack Query. Styling via Tailwind v4 (+ shadcn if enabled).

## Project Structure

| Directory                | Purpose                                                        |
| ------------------------ | -------------------------------------------------------------- |
| `src/pages/`             | TanStack Router file-based routes (`page.tsx` convention)      |
| `src/components/ui/`     | shadcn/UI primitives. Composed, never edited by feature code.  |
| `src/components/layout/` | Cross-page layout primitives                                   |
| `src/hooks/`             | Cross-page hooks (>=2 routes use it)                           |
| `src/stores/`            | Global Zustand stores                                          |
| `src/contexts/`          | Global React context providers                                 |
| `src/lib/`               | `cn()`, `queryClient` — no React imports                       |
| `src/utils/`             | `callApi()`, boundary code                                     |
| `src/config/`            | Env/credential access (zod-validated `env.ts`)                 |
| `src/constants/`         | App-wide enums and constants                     |
| `src/styles/`            | Global CSS, design tokens, Tailwind imports                    |
| `src/routeTree.gen.ts`   | **Auto-generated by TanStack Router. Never edit.**             |

## Build Commands

```bash
npm run dev            # Vite dev server (localhost:3000)
npm run build          # tsc -b && vite build
npm run gen:routes     # Regenerate src/routeTree.gen.ts
```

## File-based Routing (TanStack Router)

- `routeToken: 'layout'` → layout route = `<route>/layout.tsx`
- `indexToken: 'page'` → index route = `<route>/page.tsx`
- `routeFileIgnorePrefix: '-'` → `-anything` excluded
- `routeFileIgnorePattern` → `components/`, `hooks/`, `utils/`, `stores/`, tests, stories excluded

### Per-route folder convention

```
src/pages/<route>/
├── page.tsx        # Route export (createFileRoute)
├── components/     # page-local components (excluded by regex)
├── hooks/          # page-local hooks
├── constants.ts
└── types.ts
```

### CRITICAL

- **Never edit `src/routeTree.gen.ts`** — run `npm run gen:routes` to refresh.
- **Never hand-write routes via `createRoute()`** — file-based only.

## State Management

- **TanStack Query** — server state. Client in `src/lib/queryClient.ts`, available via router context.
- **Zustand** — global client state. One store per concern under `src/stores/`.
- **`useState`/`useReducer`** — component-local state.

## Data Fetching

- All HTTP via `callApi()` in `src/utils/api.ts`. Never raw `fetch()` in feature code.
- Route-level fetch via loaders:

```tsx
export const Route = createFileRoute('/posts/$id')({
  loader: ({ context: { queryClient }, params }) =>
    queryClient.ensureQueryData(postQueryOptions(params.id)),
  component: PostPage
});
```

## Styling

- Tailwind v4 with CSS variables for design tokens (`src/styles/globals.css`).
- Dark mode via `.dark` class on `<html>`, controlled by `src/stores/themeStore.ts`.
- Borders: `border-border`. Never hardcoded colors — use tokens.

## Validation

- Zod for all runtime validation: env (`src/config/env.ts`), API responses, forms.

## What Not To Do

- Raw `fetch()` — use `callApi()`
- Hardcoded route path strings in `<Link>`/`navigate` — rely on router type-safety from `routeTree.gen.ts`
- Editing `src/routeTree.gen.ts` manually
- Hardcoded color values — use design tokens
EOF

echo ""
echo "Done. Next:"
echo "  cd $NAME && $PM run dev"
$SHADCN || echo "  (shadcn skipped — rerun with --shadcn or '$X shadcn@latest init' later)"
