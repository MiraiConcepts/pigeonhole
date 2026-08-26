# pigeonhole

pigeonhole is a document classification pipeline for document organization.

# Capabilities

pigeonhole reads a document dropped into a synced folder, proposes where it
belongs and what it should be called, and files it on approval.

- A document dropped at the root of the synced folder is classified the moment it
  arrives, from any device that syncs the folder.
- A single model call proposes the destination folder, the document type, the
  owner, the printed date, and a filename built from all of them.
- The proposal arrives as a notification with Accept and Discard buttons. Nothing
  moves without a tap.
- State is the filesystem itself. A document is at the root, in staging, in a
  numbered folder or in the bin, so listing the directory answers what the system
  is doing.
- Clean proposals are batched into a single notification. Anything doubtful gets
  its own, and anything blocked gets no Accept button at all.
- A staged document is nudged after a day and moved to the bin after a week.
  Accept still files it from the bin, and nothing is ever destroyed without a tap.
- Path segments are validated and the resolved destination is asserted to sit
  inside the document tree, so a proposed name cannot escape it.
- The classification vocabulary is read from the document tree rather than
  committed, so the real folder names, owners and institutions never leave the
  machine.
- A document parked by a model failure is reclassified in place on a daily retry,
  never moved back to the root, where the move would replicate to every device
  for the length of the outage.
