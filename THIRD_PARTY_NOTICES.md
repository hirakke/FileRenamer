# Third-Party Notices

## MobileFaceNet model

FileRenamer's optional local face-grouping experiment includes a converted
MobileFaceNet model from Qualcomm AI Hub Models v0.61.0.

- Model card: https://huggingface.co/qualcomm/MobileFaceNet
- Recipe: https://github.com/qualcomm/ai-hub-models/tree/v0.61.0/src/qai_hub_models/models/mobile_facenet
- Model and weights license: Apache License 2.0
- Qualcomm recipe license: BSD 3-Clause License

The complete license texts are bundled in the app under `Resources/Legal`.
Conversion provenance and checksums are recorded in
`Resources/Models/MobileFaceNet-METADATA.json`.

MobileFaceNet is used only on the user's Mac. FileRenamer does not send face
images or embeddings to a server.

Qualcomm and the MobileFaceNet authors do not endorse FileRenamer.

## Design references

The offline face-grouping design was independently implemented after reviewing
the following open-source projects. Their source code is not included in
FileRenamer.

- UnlikeOtherAI/Faces (MIT), revision
  `8bd922e2c71b40833b247425abf8aa9566723925`
  — https://github.com/UnlikeOtherAI/Faces
- mattt/DBSCAN (MIT), revision
  `9e0bac44de48b981fb1afcea1f2d29320e306c1a`
  — https://github.com/mattt/DBSCAN

The project names and contributor names are provided only for attribution and
do not imply endorsement of FileRenamer.
