from omegaconf import OmegaConf
import torch
import random
from torch.utils import data 
import os
import numpy as np
from scipy.io import wavfile
from datasets import register_dataset
from preprocessors import STFTPreprocessor
from util.mask_utils import mask_inputs
import h5py

@register_dataset(name="masked_tf_dataset_h5")
class MaskedTFDatasetH5(data.Dataset):
    def __init__(self, cfg, task_cfg=None, preprocessor_cfg=None):
        #THE PLAN
        #also make masked_tf_datased_from_cached
        self.cfg = cfg
        self.task_cfg = task_cfg
        manifest_path = cfg.data
        manifest_path = os.path.join(manifest_path, "manifest.tsv")
        with open(manifest_path, "r") as f:
            lines = f.readlines() 
        self.root_dir = lines[0].strip()
        files, lengths = [], []
        for x in lines[1:]:
            row = x.strip().split('\t')
            files.append(row[0])
            lengths.append(row[1])
        self.files, self.lengths = files, lengths

        if 'max_samples' in cfg:
            self.files = self.files[:cfg.max_samples]
            self.lengths = self.lengths[:cfg.max_samples]

        self.h5_files = {}
        if 'cached_features' in cfg:
            raise NotImplementedError("Cached features not implemented for HDF5 dataset")
        elif preprocessor_cfg.name=="stft":
            extracter = STFTPreprocessor(preprocessor_cfg)
            self.extracter = extracter
        else:
            raise RuntimeError("Specify preprocessor")

    def get_input_dim(self):
        item = self.__getitem__(0)
        return item["masked_input"].shape[-1]


    def __len__(self):
        return len(self.lengths)

    def __getitem__(self, idx):
        file_name = self.files[idx]

        # file_path = os.path.join(self.root_dir, file_name)
        # data = np.load(file_path)

        h5_path = os.path.join(
            self.root_dir, "{}_{}.h5".format(file_name.split("/")[:2]))
        if h5_path not in self.h5_files:
            self.h5_files[h5_path] = h5py.File(h5_path, 'r')
        data = self.h5_files[h5_path][file_name][()]

        data = data.astype('float32')
        #rand_len = random.randrange(1000, len(data), 1)
        rand_len = -1
        wav = data[:rand_len]

        data = self.extracter(wav)

        masked_data, mask_label = mask_inputs(data, self.task_cfg) 
        return {"masked_input": masked_data,
                "length": data.shape[0],
                "mask_label": mask_label,
                "wav": wav,
                "target": data}
