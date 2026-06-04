#include "Core/Allocator.h"
#include <cstdlib>
#include <cstring>

namespace mf {

LinearAllocator::LinearAllocator(size_t capacity)
    : m_capacity(capacity), m_offset(0) {
    m_buffer = static_cast<uint8_t*>(std::aligned_alloc(16, capacity));
}

LinearAllocator::~LinearAllocator() {
    if (m_buffer) std::free(m_buffer);
}

uint8_t* LinearAllocator::allocate(size_t size, size_t alignment) {
    size_t mask = alignment - 1;
    size_t addr = (m_offset + mask) & ~mask;
    if (addr + size > m_capacity) return nullptr;
    m_offset = addr + size;
    return m_buffer + addr;
}

void LinearAllocator::reset() {
    m_offset = 0;
}

} // namespace mf
