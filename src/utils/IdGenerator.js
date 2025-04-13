// src/utils/IdGenerator.js
// (Keep the existing implementation - no React code here)

class IdGenerator {
  constructor() {
    this.counter = 0;
    this.lastTimestamp = 0;
    this.usedIds = new Set();
    this.maxTrackedIds = 1000;
  }

  generate(prefix = '') {
    const timestamp = Date.now();
    if (timestamp !== this.lastTimestamp) {
      this.counter = 0;
      this.lastTimestamp = timestamp;
    } else {
      this.counter++;
    }
    const random = Math.random().toString(36).substring(2, 5);
    let id = `${prefix}${timestamp}-${this.counter}-${random}`;

    if (this.usedIds.has(id)) {
      this.counter++; // Ensure uniqueness even in rapid calls
      return this.generate(prefix);
    }
    this.usedIds.add(id);
    if (this.usedIds.size > this.maxTrackedIds) {
      const idsArray = Array.from(this.usedIds);
      this.usedIds = new Set(idsArray.slice(this.maxTrackedIds / 2));
    }
    return id;
  }

  generateKey(prefix = 'key-') {
    return this.generate(prefix);
  }
}

export const idGenerator = new IdGenerator();