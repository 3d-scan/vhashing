#include <vhashing.h>
#include <unordered_map>
#include <utility>
#include <random>
#include <cuda_runtime.h>
#include <glog/logging.h>

using std::vector;
using std::default_random_engine;

struct Voxel {
  float sdf;
};
struct VoxelBlock {
  Voxel voxels[8*8*8];
};

bool operator==(const VoxelBlock &a, const VoxelBlock &b) {
	for (int i=0; i<8*8*8; i++) {
		if (a.voxels[i].sdf != b.voxels[i].sdf) {
			return false;
		}
	}
	return true;
}

struct BlockHasher {
	__device__ __host__
	size_t operator()(int3 patch) const {
		const size_t p[] = {
			73856093,
			19349669,
			83492791
		};
		return ((size_t)patch.x * p[0]) ^
					 ((size_t)patch.y * p[1]) ^
					 ((size_t)patch.z * p[2]);
	}
};
struct BlockEqual {
	__device__ __host__
	bool operator()(int3 patch1, int3 patch2) const {
		return patch1.x == patch2.x &&
						patch1.y == patch2.y &&
						patch1.z == patch2.z;
	}
};

typedef vhashing::HashTableBase<int3, VoxelBlock, BlockHasher, BlockEqual> HTBase;

struct X_is_even {
  __device__
  bool operator() (int3 d, VoxelBlock) {
    return (d.x % 2) == 0;
  }
};

__global__
void kernel(int3 *keys,
    VoxelBlock *values,
    int n,
    vhashing::HashTableBase<int3, VoxelBlock, BlockHasher, BlockEqual> bm) {
	int base = blockDim.x * blockIdx.x  +  threadIdx.x;
  if (base >= n) {
    return;
  }
  bm[keys[base]] = values[base];
}

__global__
void set_minus_one(
    HTBase::HashEntry *keys,
    int n,
    HTBase ht)
{
	int index = blockDim.x * blockIdx.x  +  threadIdx.x;
  if (index >= n) {
    return;
  }

  ht[keys[index]].voxels[0].sdf = -1;
}


/**
  Creates a HashTable with capacity of < 20000.

  insert voxels to hashtable until close to capacity.

  Tests the INSERT on the linked-list implementation
  */
int main() {
  vhashing::HashTable<int3, VoxelBlock, BlockHasher, BlockEqual, vhashing::device_memspace>
    blocks(10000, 2, 19997, int3{999999, 999999, 999999});

	vector< int3 > keys;
	vector< VoxelBlock > values;

	default_random_engine dre;
	for (int i=0; i<19000; i++) {
		int3 k = make_int3( dre() % 80000, dre() % 80000, dre() % 80000 );
		VoxelBlock d;

		for (int j=0; j<8*8*8; j++) {
			d.voxels[j].sdf = dre();
		}
		
		values.push_back(d);
		keys.push_back(k);
	}

	printf("Generated values\n");

	// insert into blockmap
	{
		int3 *dkeys;
		VoxelBlock *dvalues;

		cudaSafeCall(cudaMalloc(&dkeys, sizeof(int3) * keys.size()));
		cudaSafeCall(cudaMalloc(&dvalues, sizeof(VoxelBlock) * keys.size()));

		cudaSafeCall(cudaMemcpy(dkeys, &keys[0], sizeof(int3) * keys.size(), cudaMemcpyHostToDevice));
		cudaSafeCall(cudaMemcpy(dvalues, &values[0], sizeof(VoxelBlock) * keys.size(), cudaMemcpyHostToDevice));

		printf("Running kernel\n");

    int numJobs = keys.size();
    int tpb = 16;
    int numBlocks = (numJobs + (tpb-1)) / tpb;
		kernel<<<numBlocks, tpb>>>(dkeys, dvalues, keys.size(), blocks);

		cudaSafeCall(cudaDeviceSynchronize());
	}

	printf("Copying back\n");

  {
    // Apply some filter... e.g. all x are even
    auto filt = blocks.Filter(X_is_even());
  
    // use kernel to do something about the values
    int numJobs = filt.second;
    int tpb = 256;
    int numBlocks = (numJobs + (tpb-1)) / tpb;
		set_minus_one<<<numBlocks, tpb>>>(
        filt.first.get(),
        filt.second,
        blocks);

    printf("%d entries filtered\n", filt.second);
  }

	// stream in
  vhashing::HashTable<int3, VoxelBlock, BlockHasher, BlockEqual, vhashing::std_memspace>
    bmh(blocks);

	// check
	for (int i=0; i<keys.size(); i++) {
		int3 key = keys[i];
		VoxelBlock &value = bmh[key];

    if (key.x % 2 == 0) {
      CHECK(value.voxels[0].sdf == -1);
    }
    else {
      CHECK(value.voxels[0].sdf != -1);
    }
	}

	return 0;

}
