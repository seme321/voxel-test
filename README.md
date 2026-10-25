# High-Performance Godot 4.x Voxel Engine

A high-performance, expandable voxel engine built with **Godot 4.x (.NET 8 C# + GDScript)**, focusing on cache-friendly data structures, zero-GC memory allocation, 64-bit bitmask dirtiness pipelines, and multi-threaded asynchronous greedy meshing.

---

## 🌟 Key Features

- **Cache-Friendly 72-Byte `VoxelBrick` Memory Model**:
  - $8^3$ (512 voxels) micro-block stored as an unmanaged 72-byte `struct` with inline 512-bit occupancy masks (`ulong[8]`).
  - Sector ($128^3$ voxels) contains 4096 bricks in a contiguous 288 KB array with contiguous 512 KB payload buffer pools.
  - **Zero GC pressure** during continuous block addition and destruction.
- **64-bit Sub-Chunk Dirty Flags Pipeline**:
  - Divides each $128^3$ sector into 64 $32^3$ sub-chunks tracked via bitwise flags (`ulong DirtySubChunksMask`).
  - Atomic batching of block modifications: modifying 40 consecutive blocks triggers only 1 remesh per sub-chunk, yielding **54.5x faster remeshing**.
- **Multi-threaded Asynchronous Greedy Meshing**:
  - Background greedy face merging executed via Godot's `WorkerThreadPool`.
  - Sub-chunk remesh latency reduced to **~2.46 ms** (79x lower latency than monolithic $128^3$ remeshing).
- **6-Way Cross-Sector Boundary Stitching**:
  - Direct topology links between adjacent sector sub-chunks (`-X, +X, -Y, +Y, -Z, +Z`).
  - Complete elimination of duplicate interior boundary faces between sectors.
- **Benchmark Suite**:
  - Built-in automated benchmark runner measuring throughput, latency, GC overhead, and boundary face culling.

---

## 📊 Benchmark Highlights

| Metric | Monolithic / Unbatched | Optimized (Sub-chunk + Dirty Flags) | Speedup / Improvement |
| :--- | :--- | :--- | :--- |
| **Continuous 40-Block Edit Remesh** | 281.74 ms | **5.17 ms** | **54.5x faster** |
| **Single Block Remesh Latency** | 194.45 ms ($128^3$) | **2.46 ms** ($32^3$) | **79x lower latency** |
| **Cross-Sector Boundary Triangles** | 152 duplicate triangles | **0 triangles** | **100% culled** |
| **Heap Allocations per Brick Modification** | Dynamic heap objects | **0 heap objects** | **Zero GC pressure** |

---

## 🏗️ Technical Architecture

```
algorithms/
  ├── data/
  │   ├── VoxelBrick.cs         # 72-byte struct with 512-bit micro-occupancy mask
  │   ├── ChunkData.cs          # 128^3 Sector data structure, dirty mask, neighbor linking
  │   └── SubChunkMesher.cs     # 32^3 sub-chunk greedy meshing implementation
  ├── test/
  │   └── BenchmarkRunner.cs    # Automated benchmark test suite
scripts/
  ├── chunk.gd                  # Sector controller, dirty flushing, Async MeshInstance management
  ├── chunck_manager.gd         # Sector streaming, neighbor topology linking
  └── character_body_3d.gd      # First-person character controller
scences/
  ├── world.tscn                # Main interactive world
  ├── chunck.tscn               # Chunk visualizer scene
  └── test/
      └── BenchmarkScene.tscn   # Automated benchmark test scene
```

---

## 🚀 Getting Started

### Prerequisites
- **Godot Engine 4.3+ (.NET edition)**
- **.NET 8.0 SDK**

### Running the Project
1. Open Godot Engine and import the `project.godot` file in this directory.
2. Build the C# solution using `.NET -> Build Project` or `dotnet build "voxel test.sln"`.
3. Press **F5** to run the world.

### Running the Benchmarks
To run the automated benchmark suite:
```bash
godot --headless scences/test/BenchmarkScene.tscn
```

---

## 🗺️ Roadmap

- [x] Phase 1: Zero-GC Memory Model & 72-Byte `VoxelBrick` struct
- [x] Phase 2: 64-bit Sub-Chunk Dirty Flags Pipeline
- [x] Phase 3: 6-way Cross-Sector Boundary Stitching & Greedy Meshing
- [ ] Phase 4: Compute Shader / Hardware Ray Tracing (VDB + Micro-DDA inside $8^3$ Brick)
- [ ] Phase 5: Voxel Physics & Dynamic Destructible Environments
