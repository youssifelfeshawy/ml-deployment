import os
import time
import pandas as pd
import numpy as np
import joblib

# Load the saved components
scaler = joblib.load('/opt/ml/minmax_scaler.pkl')
rf_binary = joblib.load('/opt/ml/rf_binary_model.pkl')
rf_multi = joblib.load('/opt/ml/rf_multi_model.pkl')
le = joblib.load('/opt/ml/label_encoder.pkl')
feature_columns = joblib.load('/opt/ml/feature_columns.pkl')
to_drop = joblib.load('/opt/ml/dropped_correlated_columns.pkl')

def preprocess_new_data(new_df):
    # Handle missing (hyphens/spaces to NaN)
    new_df.replace(["-", " "], np.nan, inplace=True)
    
    # Drop highly correlated features using saved list
    new_df.drop(columns=to_drop, inplace=True, errors='ignore')
    
    # Select only the feature columns used in training
    new_df = new_df[feature_columns]
    
    # Normalize
    new_scaled = pd.DataFrame(scaler.transform(new_df), columns=new_df.columns)
    
    return new_scaled

def predict(X_new):
    # Binary prediction
    pred_binary = rf_binary.predict(X_new)
    
    # Initialize predictions as 'Normal'
    predictions = np.array(['Normal'] * len(pred_binary), dtype=object)
    
    # For predicted attacks, run multi-class
    mask_attack = (pred_binary == 1)
    if np.any(mask_attack):
        X_attack = X_new[mask_attack]
        pred_multi = rf_multi.predict(X_attack)
        predictions[mask_attack] = le.inverse_transform(pred_multi)
    
    return predictions

# Directory to monitor for new CSVs
mon_dir = '/tmp/captures'
processed_files = set()

print("Monitoring /tmp/captures for new CSVs... Press Ctrl+C to stop.")

try:
    while True:
        time.sleep(10)  # Check every 10 seconds
        current_files = {f for f in os.listdir(mon_dir) if f.endswith('.csv')}
        new_files = current_files - processed_files
        
        for file in new_files:
            try:
                file_path = os.path.join(mon_dir, file)
                df_new = pd.read_csv(file_path)
                if not df_new.empty:
                    preprocessed = preprocess_new_data(df_new)
                    preds = predict(preprocessed.values)
                    for i, pred in enumerate(preds):
                        print(f"Prediction for flow {i + 1} in {file}: {pred}")
                processed_files.add(file)
            except Exception as e:
                print(f"Error processing {file}: {e}")
except KeyboardInterrupt:
    print("Monitoring stopped.")
