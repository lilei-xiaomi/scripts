#!/bin/bash
# Delete multiple Vultr instances by ID
# Usage: ./delete_instances.sh <id1> <id2> <id3> ...

if [ $# -eq 0 ]; then
  echo "Usage: $0 <instance-id> [instance-id ...]"
  exit 1
fi

for id in "$@"; do
  echo "Deleting instance $id..."
  vultr instance delete "$id"
done
