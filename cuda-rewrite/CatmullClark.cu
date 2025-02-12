#include <omp.h>
#include <cuda.h>
#include <iostream>
#include "Utilities.h"
#include "Mesh.h"
#include "CatmullClark.h"

#define NUM_THREADS 1024
#define TID (threadIdx.x + blockIdx.x * blockDim.x)
#define CHECK_TID(count) if (TID >= count) return;
#define EACH_ELEM(num_elems) (num_elems + NUM_THREADS - 1) / NUM_THREADS, NUM_THREADS

#define NUM_GPUS 1
#define PER_GPU(num_elems) (num_elems + NUM_GPUS - 1)/NUM_GPUS	
#define NEW_TID(gpu_id, num_elems) (threadIdx.x + blockIdx.x * blockDim.x + gpu_id * PER_GPU(num_elems))	
#define EACH_ELEM_GPU(num_elems) (PER_GPU(num_elems) + NUM_THREADS - 1) / NUM_THREADS, NUM_THREADS

/*******************************************************************************
 * RefineCageHalfedges -- Applies halfedge refinement rules on the cage mesh
 *
 * This routine computes the halfedges of the control cage after one subdivision
 * step and stores them in the subd.
 *
 */
__global__ void RefineCageInner(const cc_Mesh *cage, int device_num, int32_t vertexCount, int32_t edgeCount, int32_t faceCount, int32_t halfedgeCount, cc_Halfedge_SemiRegular *halfedgesOut){
    // CHECK_TID(halfedgeCount)
    // int32_t halfedgeIDold = TID;

    int32_t halfedgeID = NEW_TID(device_num, halfedgeCount);
    if(halfedgeID >= halfedgeCount || halfedgeID >= ((device_num + 1) * PER_GPU(halfedgeCount)) ){	
        return;	
    }
    const int32_t twinID = ccm_HalfedgeTwinID(cage, halfedgeID);
    const int32_t prevID = ccm_HalfedgePrevID(cage, halfedgeID);
    const int32_t nextID = ccm_HalfedgeNextID(cage, halfedgeID);
    const int32_t faceID = ccm_HalfedgeFaceID(cage, halfedgeID);
    const int32_t edgeID = ccm_HalfedgeEdgeID(cage, halfedgeID);
    const int32_t prevEdgeID = ccm_HalfedgeEdgeID(cage, prevID);
    const int32_t prevTwinID = ccm_HalfedgeTwinID(cage, prevID);
    const int32_t vertexID = ccm_HalfedgeVertexID(cage, halfedgeID);
    const int32_t twinNextID = twinID >= 0 ? ccm_HalfedgeNextID(cage, twinID) : -1;
    
    cc_Halfedge_SemiRegular *newHalfedges[4] = {
        &halfedgesOut[(4 * halfedgeID + 0)],
        &halfedgesOut[(4 * halfedgeID + 1)],
        &halfedgesOut[(4 * halfedgeID + 2)],
        &halfedgesOut[(4 * halfedgeID + 3)]
    };

    // twinIDs
    newHalfedges[0]->twinID = 4 * twinNextID + 3;
    newHalfedges[1]->twinID = 4 * nextID     + 2;
    newHalfedges[2]->twinID = 4 * prevID     + 1;
    newHalfedges[3]->twinID = 4 * prevTwinID + 0;

    // edgeIDs
    newHalfedges[0]->edgeID = 2 * edgeID + (halfedgeID > twinID ? 0 : 1);
    newHalfedges[1]->edgeID = 2 * edgeCount + halfedgeID;
    newHalfedges[2]->edgeID = 2 * edgeCount + prevID;
    newHalfedges[3]->edgeID = 2 * prevEdgeID + (prevID > prevTwinID ? 1 : 0);

    // vertexIDs
    newHalfedges[0]->vertexID = vertexID;
    newHalfedges[1]->vertexID = vertexCount + faceCount + edgeID;
    newHalfedges[2]->vertexID = vertexCount + faceID;
    newHalfedges[3]->vertexID = vertexCount + faceCount + prevEdgeID;
}


void ccs__RefineCageHalfedges(cc_Subd *subd)
{
    const cc_Mesh *cage = subd->cage;
    const int32_t vertexCount = ccm_VertexCount(cage);
    const int32_t edgeCount = ccm_EdgeCount(cage);
    const int32_t faceCount = ccm_FaceCount(cage);
    const int32_t halfedgeCount = ccm_HalfedgeCount(cage);
    cc_Halfedge_SemiRegular *halfedgesOut = subd->halfedges;

    for(int i = 0; i < NUM_GPUS; i++){
        cudaSetDevice(i); 
        RefineCageInner<<<EACH_ELEM_GPU(halfedgeCount)>>>(cage, i, vertexCount, edgeCount, faceCount, halfedgeCount, halfedgesOut);
    }
    
}

__global__ void RefineInnerHalfedges(cc_Subd *subd, int32_t depth, int device_num, const cc_Mesh *cage, int32_t halfedgeCount, int32_t vertexCount, int32_t edgeCount, int32_t faceCount, int32_t stride, cc_Halfedge_SemiRegular *halfedgesOut){
    // CHECK_TID(halfedgeCount)
    // int32_t halfedgeIDold = TID;

    int32_t halfedgeID = NEW_TID(device_num, halfedgeCount);
    if(halfedgeID >= halfedgeCount || halfedgeID >= ((device_num + 1) * PER_GPU(halfedgeCount)) ){	
        return;	
    }

    const int32_t twinID = ccs_HalfedgeTwinID(subd, halfedgeID, depth);
    const int32_t prevID = ccm_HalfedgePrevID_Quad(halfedgeID);
    const int32_t nextID = ccm_HalfedgeNextID_Quad(halfedgeID);
    const int32_t faceID = ccm_HalfedgeFaceID_Quad(halfedgeID);
    const int32_t edgeID = ccs_HalfedgeEdgeID(subd, halfedgeID, depth);
    const int32_t vertexID = ccs_HalfedgeVertexID(subd, halfedgeID, depth);
    const int32_t prevEdgeID = ccs_HalfedgeEdgeID(subd, prevID, depth);
    const int32_t prevTwinID = ccs_HalfedgeTwinID(subd, prevID, depth);
    const int32_t twinNextID = ccm_HalfedgeNextID_Quad(twinID);
    cc_Halfedge_SemiRegular *newHalfedges[4] = {
        &halfedgesOut[(4 * halfedgeID + 0)],
        &halfedgesOut[(4 * halfedgeID + 1)],
        &halfedgesOut[(4 * halfedgeID + 2)],
        &halfedgesOut[(4 * halfedgeID + 3)]
    };

    // twinIDs
    newHalfedges[0]->twinID = 4 * twinNextID + 3;
    newHalfedges[1]->twinID = 4 * nextID     + 2;
    newHalfedges[2]->twinID = 4 * prevID     + 1;
    newHalfedges[3]->twinID = 4 * prevTwinID + 0;

    // edgeIDs
    newHalfedges[0]->edgeID = 2 * edgeID + (halfedgeID > twinID ? 0 : 1);
    newHalfedges[1]->edgeID = 2 * edgeCount + halfedgeID;
    newHalfedges[2]->edgeID = 2 * edgeCount + prevID;
    newHalfedges[3]->edgeID = 2 * prevEdgeID + (prevID > prevTwinID ? 1 : 0);

    // vertexIDs
    newHalfedges[0]->vertexID = vertexID;
    newHalfedges[1]->vertexID = vertexCount + faceCount + edgeID;
    newHalfedges[2]->vertexID = vertexCount + faceID;
    newHalfedges[3]->vertexID = vertexCount + faceCount + prevEdgeID;
}


/*******************************************************************************
 * RefineHalfedges -- Applies halfedge refinement on the subd
 *
 * This routine computes the halfedges of the next subd level.
 *
 */
static void ccs__RefineHalfedges(cc_Subd *subd, int32_t depth)
{
    const cc_Mesh *cage = subd->cage;
    const int32_t halfedgeCount = ccm_HalfedgeCountAtDepth(cage, depth);
    const int32_t vertexCount = ccm_VertexCountAtDepth_Fast(cage, depth);
    const int32_t edgeCount = ccm_EdgeCountAtDepth_Fast(cage, depth);
    const int32_t faceCount = ccm_FaceCountAtDepth_Fast(cage, depth);
    const int32_t stride = ccs_CumulativeHalfedgeCountAtDepth(cage, depth);
    cc_Halfedge_SemiRegular *halfedgesOut = &subd->halfedges[stride];

    for(int i = 0; i < NUM_GPUS; i++){
        cudaSetDevice(i); 
        RefineInnerHalfedges<<<EACH_ELEM_GPU(halfedgeCount)>>>(subd, depth, i, cage, halfedgeCount, vertexCount, edgeCount, faceCount, stride, halfedgesOut);
    }
}


/*******************************************************************************
 * RefineHalfedges
 *
 */
void ccs_RefineHalfedges(cc_Subd *subd)
{
    const int32_t maxDepth = ccs_MaxDepth(subd);

    ccs__RefineCageHalfedges(subd);
    cudaDeviceSynchronize();

    for (int32_t depth = 1; depth < maxDepth; ++depth) {
        ccs__RefineHalfedges(subd, depth);
        cudaDeviceSynchronize(); // seems to not be necessary? We'll see.
    }
}

/*******************************************************************************
 * RefineVertexPoints -- Computes the result of Catmull Clark subdivision.
 *
 */
void ccs__ClearVertexPoints(cc_Subd *subd)
{
    const int32_t vertexCount = ccs_CumulativeVertexCount(subd);
    const int32_t vertexByteCount = vertexCount * sizeof(cc_VertexPoint);

    CC_MEMSET(subd->vertexPoints, 0, vertexByteCount);
}


__global__ void ccs__CageFacePoints_Scatter_Inner(const cc_Mesh *cage, int32_t vertexCount, int32_t halfedgeCount, cc_VertexPoint *newFacePoints)
{
    CHECK_TID(halfedgeCount)
    int32_t halfedgeID = TID;
    const cc_VertexPoint vertexPoint = ccm_HalfedgeVertexPoint(cage, halfedgeID);
    const int32_t faceID = ccm_HalfedgeFaceID(cage, halfedgeID);
    double faceVertexCount = 1.0f;
    double *newFacePoint = newFacePoints[faceID].array;

    for (int32_t halfedgeIt = ccm_HalfedgeNextID(cage, halfedgeID);
                    halfedgeIt != halfedgeID;
                    halfedgeIt = ccm_HalfedgeNextID(cage, halfedgeIt)) {
        ++faceVertexCount;
    }

    for (int32_t i = 0; i < 3; ++i) {
// CC_ATOMIC
        // newFacePoint[i]+= vertexPoint.array[i] / (double)faceVertexCount;
        atomicAdd(newFacePoint + i, vertexPoint.array[i] / (double)faceVertexCount);
    }
}

void ccs__CageFacePoints_Scatter(cc_Subd *subd)
{
    const cc_Mesh *cage = subd->cage;
    const int32_t vertexCount = ccm_VertexCount(cage);
    const int32_t halfedgeCount = ccm_HalfedgeCount(cage);
    cc_VertexPoint *newFacePoints = &subd->vertexPoints[vertexCount];

    ccs__CageFacePoints_Scatter_Inner<<<EACH_ELEM(halfedgeCount)>>>(cage, vertexCount, halfedgeCount, newFacePoints);

}

__global__ void ccs__CreasedCageEdgePoints_Scatter_Inner(const cc_Mesh *cage, int32_t faceCount, int32_t vertexCount, int32_t halfedgeCount, const cc_VertexPoint *newFacePoints, cc_VertexPoint *newEdgePoints)
{
    CHECK_TID(halfedgeCount)
    int32_t halfedgeID = TID;
    const int32_t faceID = ccm_HalfedgeFaceID(cage, halfedgeID);
    const int32_t edgeID = ccm_HalfedgeEdgeID(cage, halfedgeID);
    const int32_t twinID = ccm_HalfedgeTwinID(cage, halfedgeID);
    const int32_t nextID = ccm_HalfedgeNextID(cage, halfedgeID);
    const double sharp = ccm_CreaseSharpness(cage, edgeID);
    const double edgeWeight = cc__Satf(sharp);
    const cc_VertexPoint newFacePoint = newFacePoints[faceID];
    const cc_VertexPoint oldEdgePoints[2] = {
        ccm_HalfedgeVertexPoint(cage, halfedgeID),
        ccm_HalfedgeVertexPoint(cage,     nextID)
    };
    cc_VertexPoint smoothPoint = {0.0f, 0.0f, 0.0f};
    cc_VertexPoint sharpPoint = {0.0f, 0.0f, 0.0f};
    double tmp[3], atomicWeight[3];

    // sharp point
    cc__Lerp3f(tmp, oldEdgePoints[0].array, oldEdgePoints[1].array, 0.5f);
    cc__Mul3f(sharpPoint.array, tmp, twinID < 0 ? 1.0f : 0.5f);

    // smooth point
    cc__Lerp3f(tmp, oldEdgePoints[0].array, newFacePoint.array, 0.5f);
    cc__Mul3f(smoothPoint.array, tmp, 0.5f);

    // atomic weight
    cc__Lerp3f(atomicWeight,
                smoothPoint.array,
                sharpPoint.array,
                edgeWeight);

    for (int32_t i = 0; i < 3; ++i) {
        atomicAdd(newEdgePoints[edgeID].array + i, atomicWeight[i]);
    }
}

void ccs__CreasedCageEdgePoints_Scatter(cc_Subd *subd)
{
    const cc_Mesh *cage = subd->cage;
    const int32_t faceCount = ccm_FaceCount(cage);
    const int32_t vertexCount = ccm_VertexCount(cage);
    const int32_t halfedgeCount = ccm_HalfedgeCount(cage);
    const cc_VertexPoint *newFacePoints = &subd->vertexPoints[vertexCount];
    cc_VertexPoint *newEdgePoints = &subd->vertexPoints[vertexCount + faceCount];
    ccs__CreasedCageEdgePoints_Scatter_Inner<<<EACH_ELEM(halfedgeCount)>>>(cage, faceCount, vertexCount, halfedgeCount, newFacePoints, newEdgePoints);
}

__global__ void ccs__CreasedCageVertexPoints_Scatter_Inner(
    const cc_Mesh *cage, int32_t faceCount, const int32_t vertexCount, int32_t halfedgeCount, 
    const cc_VertexPoint *oldVertexPoints, const cc_VertexPoint *newFacePoints, 
    const cc_VertexPoint *newEdgePoints, cc_VertexPoint *newVertexPoints)
{
    CHECK_TID(halfedgeCount)
    int32_t halfedgeID = TID;
    const int32_t vertexID = ccm_HalfedgeVertexID(cage, halfedgeID);
    const int32_t edgeID = ccm_HalfedgeEdgeID(cage, halfedgeID);
    const int32_t faceID = ccm_HalfedgeFaceID(cage, halfedgeID);
    const int32_t prevID = ccm_HalfedgePrevID(cage, halfedgeID);
    const int32_t prevEdgeID = ccm_HalfedgeEdgeID(cage, prevID);
    const double thisS = ccm_HalfedgeSharpness(cage, halfedgeID);
    const double prevS = ccm_HalfedgeSharpness(cage,     prevID);
    const double creaseWeight = cc__Signf(thisS);
    const double prevCreaseWeight = cc__Signf(prevS);
    const cc_VertexPoint newPrevEdgePoint = newEdgePoints[prevEdgeID];
    const cc_VertexPoint newEdgePoint = newEdgePoints[edgeID];
    const cc_VertexPoint newFacePoint = newFacePoints[faceID];
    const cc_VertexPoint oldPoint = oldVertexPoints[vertexID];
    cc_VertexPoint cornerPoint = {0.0f, 0.0f, 0.0f};
    cc_VertexPoint smoothPoint = {0.0f, 0.0f, 0.0f};
    cc_VertexPoint creasePoint = {0.0f, 0.0f, 0.0f};
    cc_VertexPoint atomicWeight = {0.0f, 0.0f, 0.0f};
    double avgS = prevS;
    double creaseCount = prevCreaseWeight;
    double valence = 1.0f;
    int32_t forwardIterator, backwardIterator;
    double tmp1[3], tmp2[3];

    for (forwardIterator = ccm_HalfedgeTwinID(cage, prevID);
            forwardIterator >= 0 && forwardIterator != halfedgeID;
            forwardIterator = ccm_HalfedgeTwinID(cage, forwardIterator)) {
        const int32_t prevID = ccm_HalfedgePrevID(cage, forwardIterator);
        const double prevS = ccm_HalfedgeSharpness(cage, prevID);
        const double prevCreaseWeight = cc__Signf(prevS);

        // valence computation
        ++valence;

        // crease computation
        avgS+= prevS;
        creaseCount+= prevCreaseWeight;

        // next vertex halfedge
        forwardIterator = prevID;
    }

    for (backwardIterator = ccm_HalfedgeTwinID(cage, halfedgeID);
            forwardIterator < 0 && backwardIterator >= 0 && backwardIterator != halfedgeID;
            backwardIterator = ccm_HalfedgeTwinID(cage, backwardIterator)) {
        const int32_t nextID = ccm_HalfedgeNextID(cage, backwardIterator);
        const double nextS = ccm_HalfedgeSharpness(cage, nextID);
        const double nextCreaseWeight = cc__Signf(nextS);

        // valence computation
        ++valence;

        // crease computation
        avgS+= nextS;
        creaseCount+= nextCreaseWeight;

        // next vertex halfedge
        backwardIterator = nextID;
    }

    // corner point
    cc__Mul3f(cornerPoint.array, oldPoint.array, 1.0f / valence);

    // crease computation: V / 4
    cc__Mul3f(tmp1, oldPoint.array, 0.25f * creaseWeight);
    cc__Mul3f(tmp2, newEdgePoint.array, 0.25f * creaseWeight);
    cc__Add3f(creasePoint.array, tmp1, tmp2);

    // smooth computation: (4E - F + (n - 3) V) / N
    cc__Mul3f(tmp1, newFacePoint.array, -1.0f);
    cc__Mul3f(tmp2, newEdgePoint.array, +4.0f);
    cc__Add3f(smoothPoint.array, tmp1, tmp2);
    cc__Mul3f(tmp1, oldPoint.array, valence - 3.0f);
    cc__Add3f(smoothPoint.array, smoothPoint.array, tmp1);
    cc__Mul3f(smoothPoint.array,
                smoothPoint.array,
                1.0f / (valence * valence));

    // boundary corrections
    if (forwardIterator < 0) {
        creaseCount+= creaseWeight;
        ++valence;

        cc__Mul3f(tmp1, oldPoint.array, 0.25f * prevCreaseWeight);
        cc__Mul3f(tmp2, newPrevEdgePoint.array, 0.25f * prevCreaseWeight);
        cc__Add3f(tmp1, tmp1, tmp2);
        cc__Add3f(creasePoint.array, creasePoint.array, tmp1);
    }

    // atomicWeight (TODO: make branchless ?)
    if (creaseCount <= 1.0f) {
        atomicWeight = smoothPoint;
    } else if (creaseCount >= 3.0f || valence == 2.0f) {
        atomicWeight = cornerPoint;
    } else {
        cc__Lerp3f(atomicWeight.array,
                    cornerPoint.array,
                    creasePoint.array,
                    cc__Satf(avgS * 0.5f));
    }
    for (int32_t i = 0; i < 3; ++i) {
        atomicAdd(newVertexPoints[vertexID].array + i, atomicWeight.array[i]);
        // newVertexPoints[vertexID].array[i]+= atomicWeight.array[i];
    }
}


void ccs__CreasedCageVertexPoints_Scatter(cc_Subd *subd)
{
    const cc_Mesh *cage = subd->cage;
    const int32_t faceCount = ccm_FaceCount(cage);
    const int32_t vertexCount = ccm_VertexCount(cage);
    const int32_t halfedgeCount = ccm_HalfedgeCount(cage);
    const cc_VertexPoint *oldVertexPoints = cage->vertexPoints;
    const cc_VertexPoint *newFacePoints = &subd->vertexPoints[vertexCount];
    const cc_VertexPoint *newEdgePoints = &subd->vertexPoints[vertexCount + faceCount];
    cc_VertexPoint *newVertexPoints = subd->vertexPoints;

    ccs__CreasedCageVertexPoints_Scatter_Inner<<<EACH_ELEM(halfedgeCount)>>>(cage, faceCount,vertexCount, halfedgeCount, oldVertexPoints,newFacePoints, newEdgePoints, newVertexPoints);
}


__global__ void ccs__FacePoints_Scatter(const cc_Subd *subd, int32_t depth, const cc_Mesh *cage, int32_t halfedgeCount, int32_t vertexCount, int32_t stride, cc_VertexPoint *newFacePoints)
{
    CHECK_TID(halfedgeCount)
    int32_t halfedgeID = TID;
    const cc_VertexPoint vertexPoint = ccs_HalfedgeVertexPoint(subd, halfedgeID, depth);
    const int32_t faceID = ccs_HalfedgeFaceID(subd, halfedgeID, depth);
    double *newFacePoint = newFacePoints[faceID].array;

    for (int32_t i = 0; i < 3; ++i) {
        // newFacePoint[i]+= vertexPoint.array[i] / (double)4.0f;
        atomicAdd(newFacePoint + i, vertexPoint.array[i] / (double)4.0f);
    }
}


void ccs__FacePoints_Scatter(cc_Subd *subd, int32_t depth)
{
    const cc_Mesh *cage = subd->cage;
    const int32_t halfedgeCount = ccm_HalfedgeCountAtDepth(cage, depth);
    const int32_t vertexCount = ccm_VertexCountAtDepth_Fast(cage, depth);
    const int32_t stride = ccs_CumulativeVertexCountAtDepth(cage, depth);
    cc_VertexPoint *newFacePoints = &subd->vertexPoints[stride + vertexCount];

    ccs__FacePoints_Scatter<<<EACH_ELEM(halfedgeCount)>>>(subd, depth, cage, halfedgeCount, vertexCount, stride, newFacePoints);
}

__global__ void ccs__CreasedEdgePoints_Scatter(const cc_Subd *subd, int32_t depth, const cc_Mesh *cage, int32_t halfedgeCount, int32_t faceCount, int32_t vertexCount, const cc_VertexPoint *newFacePoints, cc_VertexPoint *newEdgePoints)
{
    CHECK_TID(halfedgeCount)
    int32_t halfedgeID = TID;
    const int32_t twinID = ccs_HalfedgeTwinID(subd, halfedgeID, depth);
    const int32_t edgeID = ccs_HalfedgeEdgeID(subd, halfedgeID, depth);
    const int32_t faceID = ccs_HalfedgeFaceID(subd, halfedgeID, depth);
    const int32_t nextID = ccs_HalfedgeNextID(subd, halfedgeID, depth);
    const double sharp = ccs_CreaseSharpness(subd, edgeID, depth);
    const double edgeWeight = cc__Satf(sharp);
    const cc_VertexPoint newFacePoint = newFacePoints[faceID];
    const cc_VertexPoint oldEdgePoints[2] = {
        ccs_HalfedgeVertexPoint(subd, halfedgeID, depth),
        ccs_HalfedgeVertexPoint(subd,     nextID, depth)
    };
    cc_VertexPoint smoothPoint = {0.0f, 0.0f, 0.0f};
    cc_VertexPoint sharpPoint = {0.0f, 0.0f, 0.0f};
    double tmp[3], atomicWeight[3];

    // sharp point
    cc__Lerp3f(tmp, oldEdgePoints[0].array, oldEdgePoints[1].array, 0.5f);
    cc__Mul3f(sharpPoint.array, tmp, twinID < 0 ? 1.0f : 0.5f);

    // smooth point
    cc__Lerp3f(tmp, oldEdgePoints[0].array, newFacePoint.array, 0.5f);
    cc__Mul3f(smoothPoint.array, tmp, 0.5f);

    // atomic weight
    cc__Lerp3f(atomicWeight,
                smoothPoint.array,
                sharpPoint.array,
                edgeWeight);

    for (int32_t i = 0; i < 3; ++i) {
// CC_ATOMIC
//         newEdgePoints[edgeID].array[i]+= atomicWeight[i];
        atomicAdd(newEdgePoints[edgeID].array + i, atomicWeight[i]);
    }
}

void ccs__CreasedEdgePoints_Scatter(cc_Subd *subd, int32_t depth)
{
    const cc_Mesh *cage = subd->cage;
    const int32_t vertexCount = ccm_VertexCountAtDepth_Fast(cage, depth);
    const int32_t faceCount = ccm_FaceCountAtDepth_Fast(cage, depth);
    const int32_t halfedgeCount = ccm_HalfedgeCountAtDepth(cage, depth);
    const int32_t stride = ccs_CumulativeVertexCountAtDepth(cage, depth);
    const cc_VertexPoint *newFacePoints = &subd->vertexPoints[stride + vertexCount];
    cc_VertexPoint *newEdgePoints = &subd->vertexPoints[stride + vertexCount + faceCount];
    ccs__CreasedEdgePoints_Scatter<<<EACH_ELEM(halfedgeCount)>>>(subd, depth, cage, halfedgeCount, faceCount, vertexCount, newFacePoints, newEdgePoints);
}

__global__ void ccs__CreasedVertexPoints_Scatter(cc_Subd *subd, int32_t depth, const cc_Mesh *cage, int32_t halfedgeCount, int32_t faceCount, int32_t vertexCount, const cc_VertexPoint *newFacePoints, const cc_VertexPoint *newEdgePoints, cc_VertexPoint *newVertexPoints)
{   
    CHECK_TID(halfedgeCount)
    int32_t halfedgeID = TID;
    const int32_t vertexID = ccs_HalfedgeVertexID(subd, halfedgeID, depth);
    const int32_t edgeID = ccs_HalfedgeEdgeID(subd, halfedgeID, depth);
    const int32_t faceID = ccs_HalfedgeFaceID(subd, halfedgeID, depth);
    const int32_t prevID = ccs_HalfedgePrevID(subd, halfedgeID, depth);
    const int32_t prevEdgeID = ccs_HalfedgeEdgeID(subd, prevID, depth);
    const double thisS = ccs_HalfedgeSharpness(subd, halfedgeID, depth);
    const double prevS = ccs_HalfedgeSharpness(subd,     prevID, depth);
    const double creaseWeight = cc__Signf(thisS);
    const double prevCreaseWeight = cc__Signf(prevS);
    const cc_VertexPoint newPrevEdgePoint = newEdgePoints[prevEdgeID];
    const cc_VertexPoint newEdgePoint = newEdgePoints[edgeID];
    const cc_VertexPoint newFacePoint = newFacePoints[faceID];
    const cc_VertexPoint oldPoint = ccs_VertexPoint(subd, vertexID, depth);
    cc_VertexPoint cornerPoint = {0.0f, 0.0f, 0.0f};
    cc_VertexPoint smoothPoint = {0.0f, 0.0f, 0.0f};
    cc_VertexPoint creasePoint = {0.0f, 0.0f, 0.0f};
    cc_VertexPoint atomicWeight = {0.0f, 0.0f, 0.0f};
    double avgS = prevS;
    double creaseCount = prevCreaseWeight;
    double valence = 1.0f;
    int32_t forwardIterator, backwardIterator;
    double tmp1[3], tmp2[3];

    for (forwardIterator = ccs_HalfedgeTwinID(subd, prevID, depth);
            forwardIterator >= 0 && forwardIterator != halfedgeID;
            forwardIterator = ccs_HalfedgeTwinID(subd, forwardIterator, depth)) {
        
        const int32_t prevID = ccs_HalfedgePrevID(subd, forwardIterator, depth);
        const double prevS = ccs_HalfedgeSharpness(subd, prevID, depth);
        const double prevCreaseWeight = cc__Signf(prevS);

        // valence computation
        ++valence;

        // crease computation
        avgS+= prevS;
        creaseCount+= prevCreaseWeight;

        // next vertex halfedge
        forwardIterator = prevID;
    }

    for (backwardIterator = ccs_HalfedgeTwinID(subd, halfedgeID, depth);
            forwardIterator < 0 && backwardIterator >= 0 && backwardIterator != halfedgeID;
            backwardIterator = ccs_HalfedgeTwinID(subd, backwardIterator, depth)) {
        const int32_t nextID = ccs_HalfedgeNextID(subd, backwardIterator, depth);
        const double nextS = ccs_HalfedgeSharpness(subd, nextID, depth);
        const double nextCreaseWeight = cc__Signf(nextS);

        // valence computation
        ++valence;

        // crease computation
        avgS+= nextS;
        creaseCount+= nextCreaseWeight;

        // next vertex halfedge
        backwardIterator = nextID;
    }

    // corner point
    cc__Mul3f(cornerPoint.array, oldPoint.array, 1.0f / valence);

    // crease computation: V / 4
    cc__Mul3f(tmp1, oldPoint.array, 0.25f * creaseWeight);
    cc__Mul3f(tmp2, newEdgePoint.array, 0.25f * creaseWeight);
    cc__Add3f(creasePoint.array, tmp1, tmp2);

    // smooth computation: (4E - F + (n - 3) V) / N
    cc__Mul3f(tmp1, newFacePoint.array, -1.0f);
    cc__Mul3f(tmp2, newEdgePoint.array, +4.0f);
    cc__Add3f(smoothPoint.array, tmp1, tmp2);
    cc__Mul3f(tmp1, oldPoint.array, valence - 3.0f);
    cc__Add3f(smoothPoint.array, smoothPoint.array, tmp1);
    cc__Mul3f(smoothPoint.array,
                smoothPoint.array,
                1.0f / (valence * valence));

    // boundary corrections
    if (forwardIterator < 0) {
        creaseCount+= creaseWeight;
        ++valence;

        cc__Mul3f(tmp1, oldPoint.array, 0.25f * prevCreaseWeight);
        cc__Mul3f(tmp2, newPrevEdgePoint.array, 0.25f * prevCreaseWeight);
        cc__Add3f(tmp1, tmp1, tmp2);
        cc__Add3f(creasePoint.array, creasePoint.array, tmp1);
    }

    // atomicWeight (TODO: make branchless ?)
    if (creaseCount >= 3.0f || valence == 2.0f) {
        atomicWeight = cornerPoint;
    } else if (creaseCount <= 1.0f) {
        atomicWeight = smoothPoint;
    } else {
        cc__Lerp3f(atomicWeight.array,
                    cornerPoint.array,
                    creasePoint.array,
                    cc__Satf(avgS * 0.5f));
    }

    for (int32_t i = 0; i < 3; ++i) {
// CC_ATOMIC
        // newVertexPoints[vertexID].array[i]+= atomicWeight.array[i];
        atomicAdd(newVertexPoints[vertexID].array + i, atomicWeight.array[i]);
    }
}


void ccs__CreasedVertexPoints_Scatter(cc_Subd *subd, int32_t depth)
{
    const cc_Mesh *cage = subd->cage;
    const int32_t halfedgeCount = ccm_HalfedgeCountAtDepth(cage, depth);
    const int32_t vertexCount = ccm_VertexCountAtDepth_Fast(cage, depth);
    const int32_t faceCount = ccm_FaceCountAtDepth_Fast(cage, depth);
    const int32_t stride = ccs_CumulativeVertexCountAtDepth(cage, depth);
    const cc_VertexPoint *newFacePoints = &subd->vertexPoints[stride + vertexCount];
    const cc_VertexPoint *newEdgePoints = &subd->vertexPoints[stride + vertexCount + faceCount];
    cc_VertexPoint *newVertexPoints = &subd->vertexPoints[stride];
    
    ccs__CreasedVertexPoints_Scatter<<<EACH_ELEM(halfedgeCount)>>>(subd, depth, cage, halfedgeCount, faceCount, vertexCount, newFacePoints, newEdgePoints, newVertexPoints);
}


void ccs_RefineVertexPoints_Scatter(cc_Subd *subd)
{
    ccs__ClearVertexPoints(subd);
    ccs__CageFacePoints_Scatter(subd);
    ccs__CreasedCageEdgePoints_Scatter(subd);
    ccs__CreasedCageVertexPoints_Scatter(subd);
    cudaDeviceSynchronize();

    for (int32_t depth = 1; depth < ccs_MaxDepth(subd); ++depth) {
        ccs__FacePoints_Scatter(subd, depth);
        ccs__CreasedEdgePoints_Scatter(subd, depth);
        ccs__CreasedVertexPoints_Scatter(subd, depth);
        cudaDeviceSynchronize();
    }
}
/*************

Start Creases Code

**************/

__global__ void ccs__RefineCageCreases_Inner(const cc_Mesh *cage, int device_num, int32_t edgeCount, cc_Crease *creasesOut){
    // CHECK_TID(edgeCount)
    // int32_t edgeID = TID;

    int32_t edgeID = NEW_TID(device_num, edgeCount);
    if(edgeID >= edgeCount  || edgeID >= ((device_num + 1) * PER_GPU(edgeCount))){
        return;	
    }

    const int32_t nextID = ccm_CreaseNextID(cage, edgeID);
    const int32_t prevID = ccm_CreasePrevID(cage, edgeID);
    const bool t1 = ccm_CreasePrevID(cage, nextID) == edgeID && nextID != edgeID;
    const bool t2 = ccm_CreaseNextID(cage, prevID) == edgeID && prevID != edgeID;
    const double thisS = 3.0f * ccm_CreaseSharpness(cage, edgeID);
    const double nextS = ccm_CreaseSharpness(cage, nextID);
    const double prevS = ccm_CreaseSharpness(cage, prevID);
    cc_Crease *newCreases[2] = {
        &creasesOut[(2 * edgeID + 0)],
        &creasesOut[(2 * edgeID + 1)]
    };

    // next rule
    newCreases[0]->nextID = 2 * edgeID + 1;
    newCreases[1]->nextID = 2 * nextID + (t1 ? 0 : 1);

    // prev rule
    newCreases[0]->prevID = 2 * prevID + (t2 ? 1 : 0);
    newCreases[1]->prevID = 2 * edgeID + 0;

    // sharpness rule
    newCreases[0]->sharpness = cc__Maxf(0.0f, (prevS + thisS) / 4.0f - 1.0f);
    newCreases[1]->sharpness = cc__Maxf(0.0f, (thisS + nextS) / 4.0f - 1.0f);
}

void ccs__RefineCageCreases(cc_Subd *subd)
{
    const cc_Mesh *cage = subd->cage;
    const int32_t edgeCount = ccm_EdgeCount(cage);
    cc_Crease *creasesOut = subd->creases;
    for(int i = 0; i < NUM_GPUS; i++){
        cudaSetDevice(i);
        ccs__RefineCageCreases_Inner<<<EACH_ELEM_GPU(edgeCount)>>>(cage, i, edgeCount, creasesOut);
    }
}

__global__ void ccs__RefineCreases(cc_Subd *subd, int32_t depth, int device_num, const cc_Mesh *cage, int32_t creaseCount, int32_t stride, cc_Crease *creasesOut)
{
    // CHECK_TID(creaseCount)
    // int32_t edgeID = TID;
    int32_t edgeID = NEW_TID(device_num, creaseCount);
    if(edgeID >= creaseCount  || edgeID >= ((device_num + 1) * PER_GPU(creaseCount))){	
        return;	
    }

    const int32_t nextID = ccs_CreaseNextID_Fast(subd, edgeID, depth);
    const int32_t prevID = ccs_CreasePrevID_Fast(subd, edgeID, depth);
    const bool t1 = ccs_CreasePrevID_Fast(subd, nextID, depth) == edgeID && nextID != edgeID;
    const bool t2 = ccs_CreaseNextID_Fast(subd, prevID, depth) == edgeID && prevID != edgeID;
    const double thisS = 3.0f * ccs_CreaseSharpness_Fast(subd, edgeID, depth);
    const double nextS = ccs_CreaseSharpness_Fast(subd, nextID, depth);
    const double prevS = ccs_CreaseSharpness_Fast(subd, prevID, depth);
    cc_Crease *newCreases[2] = {
        &creasesOut[(2 * edgeID + 0)],
        &creasesOut[(2 * edgeID + 1)]
    };

    // next rule
    newCreases[0]->nextID = 2 * edgeID + 1;
    newCreases[1]->nextID = 2 * nextID + (t1 ? 0 : 1);

    // prev rule
    newCreases[0]->prevID = 2 * prevID + (t2 ? 1 : 0);
    newCreases[1]->prevID = 2 * edgeID + 0;

    // sharpness rule
    newCreases[0]->sharpness = cc__Maxf(0.0f, (prevS + thisS) / 4.0f - 1.0f);
    newCreases[1]->sharpness = cc__Maxf(0.0f, (thisS + nextS) / 4.0f - 1.0f);
}

/*******************************************************************************
 * RefineCreases -- Applies crease subdivision on the subd
 *
 * This routine computes the topology of the next subd level.
 *
 */
void ccs__RefineCreases(cc_Subd *subd, int32_t depth)
{
    const cc_Mesh *cage = subd->cage;
    const int32_t creaseCount = ccm_CreaseCountAtDepth(cage, depth);
    const int32_t stride = ccs_CumulativeCreaseCountAtDepth(cage, depth);
    cc_Crease *creasesOut = &subd->creases[stride];

    for(int i = 0; i < NUM_GPUS; i++){
        cudaSetDevice(i);
        ccs__RefineCreases<<<EACH_ELEM_GPU(creaseCount)>>>(subd, depth, i, cage, creaseCount, stride, creasesOut);
    }
    
}

void ccs_RefineCreases(cc_Subd *subd)
{
    const int32_t maxDepth = ccs_MaxDepth(subd);

    ccs__RefineCageCreases(subd);
    cudaDeviceSynchronize();

    for (int32_t depth = 1; depth < maxDepth; ++depth) {
        ccs__RefineCreases(subd, depth);
        cudaDeviceSynchronize();
    }
}

// __global__ void touch_memory(cc_Subd *subd, int device_num, int depth)
// {
//         const cc_Mesh *cage = subd->cage;

//         const int32_t creaseCount = ccm_CreaseCountAtDepth(cage, depth);
//         // do something that requires the memory be here
//         // CHECK_ASSIGN_TID(edgeID, creaseCount)
//         // // int32_t edgeID = TID;
//         int32_t edgeID = NEW_TID(device_num, creaseCount);
//         if(edgeID >= creaseCount  || edgeID >= ((device_num + 1) * PER_GPU(creaseCount))){
//             return;	
//         }
//         const int32_t nextID = ccs_CreaseNextID_Fast(subd, edgeID, depth);
//         const int32_t prevID = ccs_CreasePrevID_Fast(subd, edgeID, depth);
//         const bool t1 = ccs_CreasePrevID_Fast(subd, nextID, depth) == edgeID && nextID != edgeID;
//         const bool t2 = ccs_CreaseNextID_Fast(subd, prevID, depth) == edgeID && prevID != edgeID;
//         const double thisS = 3.0f * ccs_CreaseSharpness_Fast(subd, edgeID, depth);
//         const double nextS = ccs_CreaseSharpness_Fast(subd, nextID, depth);
//         const double prevS = ccs_CreaseSharpness_Fast(subd, prevID, depth);

// }

// void touch_memory(cc_Subd *subd, int32_t maxDepth)
// {
//     const int32_t creaseCount = ccm_CreaseCountAtDepth(subd->cage, maxDepth);
//     #pragma omp parallel for
//     for(int i = 0; i < NUM_GPUS; i++){
//         cudaSetDevice(i);
//         touch_memory<<<EACH_ELEM_GPU(creaseCount)>>>(subd, i, maxDepth);
//     }

//     cudaDeviceSynchronize();
// }